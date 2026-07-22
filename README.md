# SMT-Attack
A Satisfiability Modulo Theories (SMT)-based tool that evaluates the security of hardware designs obfuscated at the High-Level Synthesis (HLS) stage through obfuscation key recovery.

## Repository Structure

```
SMT Attack Code/
│── Obfuscated File/          # Obfuscated Verilog designs 	<design>_obfuscated_hls.v
│── Oracle/              # Original (oracle) Verilog designs	<design>_hls.v
│── Smt_Attack.py        # Main script for performing the SMT-based attack
```

### Obfuscated/
Contains the HLS-obfuscated Verilog designs to be analyzed.

### Oracle/
Contains the corresponding original (unobfuscated) Verilog designs that act as the oracle during the attack.

### Smt_Attack.py
The main Python script that performs the SMT-based key recovery attack by generating SMT constraints, querying the oracle, and recovering the correct obfuscation key.

# SMT Attack on High-Level-Synthesis Obfuscation

An SMT-based framework for analyzing the security of hardware obfuscation applied at the high-level synthesis stage, through key recovery. Given a locked (obfuscated) design and its functional oracle, the framework recovers a key that unlocks the design. It is oracle-guided and works on any design obfuscated at the high-level synthesis stage, independent of the specific obfuscation technique.

## Requirements

- Python 3.8+
- [Z3](https://github.com/Z3Prover/z3): `pip install z3-solver`

## Usage

```bash
python SMT_Attack.py
```

The script lists every obfuscated design in `Obfuscated Files/` and asks which one to break. It then finds the matching oracle in `Oracle/` (the same name with `_obfuscated` removed, e.g. `iirb_obfuscated_hls.v` → `iirb_hls.v`). Because the attack is oracle-guided, it stops with a message if the oracle is missing. On success it prints the recovered key, the number of distinguishing inputs used, and the runtime.

Optional self-check — plugs the recovered key back into the design and verifies it against the oracle on random inputs:

```bash
python SMT_Attack.py --selfcheck
```

> If your folders are located elsewhere, edit `OBF_DIR` and `ORACLE_DIR` at the top of
> `SMT_Attack.py`.

## How it works

The attack keeps two independent symbolic key copies and searches for an input on which they disagree (a distinguishing input). It queries the oracle on that input and constrains every candidate key to match. Each such input eliminates at least one wrong key class; when no distinguishing input remains, the key is uniquely determined and read out. 

## Sample Output

A full example run of the attack is available in
[Output/sample_output.txt](Output/sample_output.txt).

## License

Released under the MIT License — see [LICENSE](LICENSE).

## Disclaimer

Provided only for academic and research purposes: evaluating the security of hardware obfuscation at HLS.
