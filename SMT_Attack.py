"""
SMT_Attack.py
---------------------
Verilog-driven smt_attack.py.

Pairing convention:
    obfuscated : <design>_obfuscated_hls.v   (in OBF_DIR)
    oracle     : <design>_hls.v              (in ORACLE_DIR)
"""

import os
import re
import sys
import time

from z3 import Solver, sat, BitVec, BitVecVal, Bools, is_true, If, Or

# ─────────────────────────────────────────────
# Paths are resolved relative to THIS script's location, so the repo works
# on any machine after cloning — no manual editing needed.
# ─────────────────────────────────────────────
BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
OBF_DIR    = os.path.join(BASE_DIR, "Obfuscated File")
ORACLE_DIR = os.path.join(BASE_DIR, "Oracle")

# ═════════════════════════════════════════════════════════════════════════
#  PART 1 — Minimal Verilog interpreter for the HLS FSM-datapath dialect
# ═════════════════════════════════════════════════════════════════════════
#
#  Accepts state labels of either style: S_CS1.. or S1.. (plus S_IDLE).
#
#  The generated modules all share this shape:
#     - ports: [N:1] key (obfuscated only), inN inputs, outN outputs
#     - combinational wires  (m1.., mul_*_o, add_*_o)
#     - an always @(*) block: case(state) ... per-CS operand steering (=)
#     - an always @(posedge clk) block: case(state) ... register updates (<=)
#  The state machine is a straight CS1 -> CS2 -> ... chain, so we simply
#  unroll it in control-step order and evaluate.
#
#  Key muxes are the ONLY place the key bits enter, via:
#     - function calls  mux8(...) / mux4(...)   → indexed select
#     - ternary         key[i] ? wrong : correct
# ─────────────────────────────────────────────────────────────────────────

def _strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


# ---- expression tokenizer + parser → tiny AST -------------------------------

_TOK_RE = re.compile(r"""
      (?P<NUM>   \d+'[bBdDhH][0-9a-fA-F_]+ | \d+ )
    | (?P<ID>    [A-Za-z_]\w* )
    | (?P<OP>    <= | == | [-+*/?:()\[\]{},] )
    | (?P<WS>    \s+ )
""", re.X)


def _tokenize(expr):
    toks = []
    for m in _TOK_RE.finditer(expr):
        if m.lastgroup == "WS":
            continue
        toks.append((m.lastgroup, m.group()))
    return toks


def _num_value(tok):
    if "'" in tok:
        _, rest = tok.split("'", 1)
        base = {"b": 2, "d": 10, "h": 16}[rest[0].lower()]
        return int(rest[1:].replace("_", ""), base)
    return int(tok)


class _Parser:
    """Recursive-descent parser for the RHS expression grammar we emit."""

    def __init__(self, toks):
        self.toks = toks
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.toks[j] if j < len(self.toks) else (None, None)

    def eat(self, txt=None):
        kind, val = self.peek()
        if txt is not None and val != txt:
            raise SyntaxError("expected %r got %r" % (txt, val))
        self.i += 1
        return val

    def parse(self):
        node = self.expr()
        return node

    # precedence: ternary < add/sub < mul/div < primary
    def expr(self):
        return self.ternary()

    def ternary(self):
        cond = self.addsub()
        if self.peek()[1] == "?":
            self.eat("?")
            a = self.ternary()
            self.eat(":")
            b = self.ternary()
            return ("tern", cond, a, b)
        return cond

    def addsub(self):
        node = self.muldiv()
        while self.peek()[1] in ("+", "-"):
            op = self.eat()
            node = ("bin", op, node, self.muldiv())
        return node

    def muldiv(self):
        node = self.primary()
        while self.peek()[1] in ("*", "/"):
            op = self.eat()
            node = ("bin", op, node, self.primary())
        return node

    def primary(self):
        kind, val = self.peek()
        if kind == "NUM":
            self.eat()
            return ("num", _num_value(val))
        if val == "(":
            self.eat("(")
            node = self.expr()
            self.eat(")")
            return node
        if val == "{":
            return self.braces()
        if kind == "ID":
            self.eat()
            if self.peek()[1] == "(":          # function call
                args = self.call_args()
                return ("call", val, args)
            if self.peek()[1] == "[":          # indexed → key[i]
                self.eat("[")
                idx = _num_value(self.eat())
                self.eat("]")
                return ("keyidx", idx)
            return ("id", val)
        raise SyntaxError("unexpected token %r" % (val,))

    def call_args(self):
        self.eat("(")
        args = []
        if self.peek()[1] != ")":
            args.append(self.expr())
            while self.peek()[1] == ",":
                self.eat(",")
                args.append(self.expr())
        self.eat(")")
        return args

    def braces(self):
        # { WIDTH { 1'b0 } }  → zero   OR   { a, b, c } → concat
        self.eat("{")
        if self.peek()[0] == "ID" and self.peek(1)[1] == "{":
            # replication → treat as zero fill
            depth = 1
            while depth:
                v = self.eat()
                if v == "{":
                    depth += 1
                elif v == "}":
                    depth -= 1
            return ("zero",)
        items = [self.expr()]
        while self.peek()[1] == ",":
            self.eat(",")
            items.append(self.expr())
        self.eat("}")
        return ("concat", items)


def _parse_expr(s):
    return _Parser(_tokenize(s)).parse()


# ---- backends ---------------------------------------------------------------

class _ZBackend:
    """Symbolic backend: BitVec arithmetic + Bool keys (for the obfuscated file)."""
    def __init__(self, width, keys):
        self.width = width
        self.keys = keys           # list of z3 Bool, index 0 == key1
    def const(self, v):  return BitVecVal(v, self.width)
    def add(self, a, b): return a + b
    def sub(self, a, b): return a - b
    def mul(self, a, b): return a * b
    def div(self, a, b): return a / b
    def mux(self, c, a, b): return If(c, a, b)
    def key(self, i):    return self.keys[i - 1]


class _PyBackend:
    """Concrete backend: plain Python integers (for the oracle file)."""
    def const(self, v):  return v
    def add(self, a, b): return a + b
    def sub(self, a, b): return a - b
    def mul(self, a, b): return a * b
    def div(self, a, b): return a // b
    def mux(self, c, a, b): return a if c else b
    def key(self, i):    raise RuntimeError("oracle referenced a key bit")


class VModule:
    """Parsed HLS FSM-datapath Verilog module + symbolic/concrete simulator."""

    def __init__(self):
        self.n_keys = 0
        self.inputs = []          # ['in1', 'in2', ...]
        self.outputs = []         # ['out1', ...]
        self.wire_ast = {}        # name -> AST
        self.comb = {}            # state -> [(target, AST)]
        self.seq = {}             # state -> [(target, AST)]
        self.idle_regs = []       # [(r_i, AST(in_i))]
        self.state_order = []     # ['S1', 'S2', ...] or ['S_CS1', ...]
        self.comb_targets = set()
        self.seq_targets = set()

    # -- parsing --------------------------------------------------------------
    @classmethod
    def parse(cls, path):
        text = _strip_comments(open(path).read())
        m = cls()

        header = text.split(");", 1)[0]         # module port list
        km = re.search(r"\[\s*(\d+)\s*:\s*1\s*\]\s+key", header)
        m.n_keys = int(km.group(1)) if km else 0
        m.inputs  = ["in%d"  % i for i in sorted(
            {int(x) for x in re.findall(r"\bin(\d+)\b",  header)})]
        m.outputs = ["out%d" % i for i in sorted(
            {int(x) for x in re.findall(r"\bout(\d+)\b", header)})]

        # continuous wire assignments (m*, mul_*_o, add_*_o)
        for name, rhs in re.findall(
                r"wire\s*(?:\[[^\]]*\])?\s*(\w+)\s*=\s*([^;]+);", text):
            m.wire_ast[name] = _parse_expr(rhs)

        comb_body = cls._case_body(text, r"always\s*@\s*\(\s*\*\s*\)")
        seq_body  = cls._case_body(text, r"always\s*@\s*\(\s*posedge")

        for state, body in cls._case_entries(comb_body):
            assigns = []
            for tgt, rhs in re.findall(r"([A-Za-z_]\w*)\s*=\s*([^;]+);", body):
                assigns.append((tgt, _parse_expr(rhs)))
                m.comb_targets.add(tgt)
            m.comb[state] = assigns

        for state, body in cls._case_entries(seq_body):
            assigns = []
            for tgt, rhs in re.findall(r"([A-Za-z_]\w*)\s*<=\s*([^;]+);", body):
                if tgt == "state":
                    continue
                node = _parse_expr(rhs)
                if state == "S_IDLE":
                    if re.match(r"r\d+$", tgt):
                        m.idle_regs.append((tgt, node))
                else:
                    assigns.append((tgt, node))
                    if tgt not in m.outputs:
                        m.seq_targets.add(tgt)
            if state != "S_IDLE":
                m.seq[state] = assigns

        # State order: any control-step state (S1.., S_CS1..), sorted by the
        # trailing integer in its name.  S_IDLE (no trailing digit) excluded.
        m.state_order = sorted(
            [s for s in m.seq if re.search(r"\d+$", s)],
            key=lambda s: int(re.search(r"(\d+)$", s).group(1)))

        if not m.inputs or not m.outputs or not m.state_order:
            raise ValueError(
                "Could not parse '%s' into the expected HLS FSM datapath "
                "(inputs=%s, outputs=%s, states=%s)."
                % (os.path.basename(path), m.inputs, m.outputs, m.state_order))
        return m

    @staticmethod
    def _case_body(text, anchor_re):
        """Return the text inside the case ... endcase that follows `anchor_re`."""
        a = re.search(anchor_re, text)
        start = text.index("case", a.end())
        depth = 0
        for t in re.finditer(r"\bcase\b|\bendcase\b", text[start:]):
            if t.group() == "case":
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    inner_start = start + re.search(r"\)", text[start:]).start() + 1
                    return text[inner_start:start + t.start()]
        raise ValueError("unbalanced case/endcase")

    @staticmethod
    def _case_entries(case_body):
        """Yield (label, body) for each  S...: ... / default: ...  entry.
        Accepts state labels like S_IDLE, S1, S10, S_CS1, ..."""
        labels = list(re.finditer(r"\b(S\w*|default)\s*:", case_body))
        for k, lab in enumerate(labels):
            name = lab.group(1)
            s = lab.end()
            e = labels[k + 1].start() if k + 1 < len(labels) else len(case_body)
            body = case_body[s:e]
            body = re.sub(r"^\s*begin", "", body)
            body = re.sub(r"end\s*$", "", body)
            if name != "default":
                yield name, body

    # -- evaluation -----------------------------------------------------------
    def _eval(self, node, be, env):
        tag = node[0]
        if tag == "num":
            return be.const(node[1])
        if tag == "zero":
            return be.const(0)
        if tag == "keyidx":
            return be.key(node[1])
        if tag == "id":
            name = node[1]
            if name in self.wire_ast:
                return self._eval(self.wire_ast[name], be, env)
            if name in env:
                return env[name]
            return be.const(0)
        if tag == "bin":
            op = node[1]
            l = self._eval(node[2], be, env)
            r = self._eval(node[3], be, env)
            return {"+": be.add, "-": be.sub, "*": be.mul, "/": be.div}[op](l, r)
        if tag == "tern":
            return be.mux(self._eval(node[1], be, env),
                          self._eval(node[2], be, env),
                          self._eval(node[3], be, env))
        if tag == "call":
            # muxN(sel_concat, op0, op1, ...) → indexed select (identity order)
            sel = node[2][0]
            idxs = [it[1] for it in sel[1]]           # key indices, MSB first
            ops = [self._eval(a, be, env) for a in node[2][1:]]
            return self._select(idxs, ops, be)
        raise ValueError("bad node %r" % (node,))

    def _select(self, key_idxs, ops, be):
        if len(ops) == 1:
            return ops[0]
        bit = be.key(key_idxs[0])
        half = len(ops) // 2
        lower = self._select(key_idxs[1:], ops[:half], be)   # bit == 0
        upper = self._select(key_idxs[1:], ops[half:], be)   # bit == 1
        return be.mux(bit, upper, lower)

    def simulate(self, be, input_vals):
        env = {}
        for name, val in zip(self.inputs, input_vals):
            env[name] = val
        for tgt, node in self.idle_regs:            # r_i <= in_i
            env[tgt] = self._eval(node, be, env)
        for r in self.seq_targets:
            env.setdefault(r, be.const(0))

        for state in self.state_order:
            for c in self.comb_targets:             # default: drive to 0
                env[c] = be.const(0)
            for tgt, node in self.comb.get(state, []):
                env[tgt] = self._eval(node, be, env)
            updates = {}
            for tgt, node in self.seq.get(state, []):
                updates[tgt] = self._eval(node, be, env)
            env.update(updates)

        outs = [env[o] for o in self.outputs]
        return outs[0] if len(outs) == 1 else tuple(outs)


# ═════════════════════════════════════════════════════════════════════════
#  PART 2 — SAT Attack (DIP-based)
# ═════════════════════════════════════════════════════════════════════════

def _add_oracle_constraints(solver, obf_motion, key_vars, dip_vals, oracle_out, bit_w):
    """Constrain key_vars so obf_motion matches oracle_out on dip_vals."""
    concrete = [BitVecVal(v, bit_w) for v in dip_vals]
    result   = obf_motion(*key_vars, *concrete)
    if isinstance(oracle_out, tuple):
        for sym_o, exp_o in zip(result, oracle_out):
            solver.add(sym_o == exp_o)
    else:
        solver.add(result == oracle_out)


def run_smt_attack(obf_motion, oracle_motion, KEY_VARS, n_inputs,
                   dip_bit_width=8, iter_timeout_ms=10000, max_iterations=200):
    """
    DIP-based SAT attack.
    iter_timeout_ms: per-iteration Z3 timeout in milliseconds (default 10s).
    max_iterations:  cap on DIP-refinement iterations (default 200).
    """
    from z3 import Or

    n_keys = len(KEY_VARS)
    BIT_W  = dip_bit_width
    start  = time.perf_counter()

    # ── Two independent key copies for DIP finder ─────────────────────────
    K1 = Bools(' '.join("k1_%d" % i for i in range(n_keys)))
    K2 = Bools(' '.join("k2_%d" % i for i in range(n_keys)))

    # ── Symbolic inputs (small width for speed) ───────────────────────────
    sym_inputs = [BitVec("x%d" % i, BIT_W) for i in range(n_inputs)]

    # ── Build DIP solver with initial distinguishing constraint ───────────
    dip_solver = Solver()
    dip_solver.set("timeout", iter_timeout_ms)

    out1 = obf_motion(*K1, *sym_inputs)
    out2 = obf_motion(*K2, *sym_inputs)

    if isinstance(out1, tuple):
        dip_solver.add(Or(*[o1 != o2 for o1, o2 in zip(out1, out2)]))
    else:
        dip_solver.add(out1 != out2)

    # ── Key solver: accumulates oracle constraints ─────────────────────────
    key_solver = Solver()
    key_solver.set("timeout", iter_timeout_ms)

    dip_count      = 0
    accepted_cases = []

    print(f"  Running DIP-based SAT attack ({n_keys} keys, {n_inputs} inputs, "
          f"{BIT_W}-bit DIP search)...")

    while True:
        # Stop after the maximum number of iterations
        if dip_count >= max_iterations:
            break
        status = dip_solver.check()

        if status != sat:
            # No distinguishing input exists — converged
            break

        dip_model  = dip_solver.model()
        dip_inputs = [dip_model.eval(x, model_completion=True).as_long()
                      for x in sym_inputs]

        # Query oracle with plain Python ints (no width restriction)
        oracle_out = oracle_motion(*dip_inputs)
        dip_count += 1
        accepted_cases.append((dip_inputs, oracle_out))

        if dip_count % 5 == 0:
            elapsed_so_far = time.perf_counter() - start
            print(f"    DIP #{dip_count}  ({elapsed_so_far:.1f}s elapsed)")

        # Constrain KEY_VARS to match oracle on this DIP
        _add_oracle_constraints(key_solver, obf_motion, KEY_VARS,
                                dip_inputs, oracle_out, BIT_W)

        # Constrain both K1 and K2 to match oracle on this DIP
        _add_oracle_constraints(dip_solver, obf_motion, K1,
                                dip_inputs, oracle_out, BIT_W)
        _add_oracle_constraints(dip_solver, obf_motion, K2,
                                dip_inputs, oracle_out, BIT_W)

    elapsed = time.perf_counter() - start

    # ── Extract final keys ────────────────────────────────────────────────
    if key_solver.check() == sat:
        final_model = key_solver.model()
        print(f"\nTime to find keys: {elapsed:.6f} seconds")
        print(f"DIPs used: {dip_count}")
        print(f"\nAudit cases (first 10):")
        for idx, (inp, out) in enumerate(accepted_cases[:10], start=1):
            print(f"  DIP {idx}: inputs={inp}, oracle_out={out}")
        print("\nFound keys!")
        for i, kv in enumerate(KEY_VARS, start=1):
            val = final_model.eval(kv, model_completion=True)
            print(f"  key{i} = {is_true(val)}")
    else:
        print(f"\nTime elapsed: {elapsed:.6f} seconds")
        print(f"DIPs used: {dip_count}")
        print("Could not determine a unique key set (unsatisfiable after DIPs).")


# ═════════════════════════════════════════════════════════════════════════
#  PART 3 — Main
# ═════════════════════════════════════════════════════════════════════════

def _oracle_name_for(obf_filename):
    """iirb_obfuscated_hls.v -> iirb_hls.v"""
    return obf_filename.replace("_obfuscated", "")


def main():
    if not os.path.isdir(OBF_DIR):
        print("Obfuscated files folder not found: %s" % OBF_DIR); sys.exit(1)
    if not os.path.isdir(ORACLE_DIR):
        print("Oracle folder not found: %s" % ORACLE_DIR); sys.exit(1)

    # ── Fetch every obfuscated Verilog design ────────────────────────────
    obf_files = sorted(f for f in os.listdir(OBF_DIR) if f.endswith(".v"))
    if not obf_files:
        print("No obfuscated Verilog (.v) files found in: %s" % OBF_DIR)
        sys.exit(1)

    print("Available obfuscated designs:")
    for i, f in enumerate(obf_files):
        print("  [%d] %s" % (i, f))

    choice   = int(input("\nSelect design number to break: "))
    obf_file = obf_files[choice]
    obf_path = os.path.join(OBF_DIR, obf_file)
    print("\nSelected: %s" % obf_file)

    # ── Oracle lookup (attack is oracle-guided) ──────────────────────────
    oracle_file = _oracle_name_for(obf_file)
    oracle_path = os.path.join(ORACLE_DIR, oracle_file)
    if not os.path.isfile(oracle_path):
        print("\n[ERROR] Corresponding oracle '%s' not found in the Oracle "
              "folder:\n        %s" % (oracle_file, ORACLE_DIR))
        print("SMT is an oracle-guided attack, so it cannot proceed without "
              "the oracle. Please add the oracle Verilog and try again.")
        sys.exit(1)
    print("Found oracle : %s" % oracle_file)

    # ── Parse both Verilog files ─────────────────────────────────────────
    obf_mod    = VModule.parse(obf_path)
    oracle_mod = VModule.parse(oracle_path)

    if obf_mod.n_keys == 0:
        print("\n[ERROR] The selected obfuscated file has no key port; "
              "nothing to recover.")
        sys.exit(1)

    print("\nDetected primary inputs : %s" % obf_mod.inputs)
    print("Detected outputs        : %s" % obf_mod.outputs)
    print("Total keys              : %d" % obf_mod.n_keys)

    # ── Build runtime functions ──────────────────────────────────────────
    all_key_names = ["key%d" % i for i in range(1, obf_mod.n_keys + 1)]
    key_syms = Bools(' '.join(all_key_names))
    KEY_VARS = (key_syms,) if obf_mod.n_keys == 1 else tuple(key_syms)

    BIT_W = 8

    def obf_motion(*args):
        keys   = args[:obf_mod.n_keys]
        inputs = args[obf_mod.n_keys:]
        be = _ZBackend(BIT_W, keys)
        return obf_mod.simulate(be, list(inputs))

    def oracle_motion(*inputs):
        be = _PyBackend()
        return oracle_mod.simulate(be, list(inputs))

    # ── Run SMT attack ───────────────────────────────────────────────────
    design_label = obf_file.replace("_obfuscated_hls.v", "").replace(".v", "")
    print(f"\nRunning SMT attack on {design_label} [Verilog]...")
    run_smt_attack(
        obf_motion, oracle_motion, KEY_VARS,
        n_inputs=len(obf_mod.inputs),
        dip_bit_width=BIT_W,
        iter_timeout_ms=10000,
        max_iterations=200,
    )


if __name__ == '__main__':
    main()
