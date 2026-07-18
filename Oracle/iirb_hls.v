//======================================================================
// iirb_hls.v
//----------------------------------------------------------------------
// RTL generated from IIRB_oracle.py via High-Level Synthesis.
//
// Oracle function:
//     t1 = in1*in2;  t2 = in3*in4;  t3 = in5*in6;
//     t4 = in7*in8;  t5 = in9*in10;
//     s1 = t1 + t2;
//     s2 = t3 + s1;
//     s3 = s2 + t4;
//     out1 = s3 + t5;    // == in1*in2 + in3*in4 + in5*in6 + in7*in8 + in9*in10
//
// Resource constraint : 2 multipliers, 3 adders
// ASAP schedule       : 5 control steps (CS1..CS5)
//
//   CS1: mul_a=t1  mul_b=t2
//   CS2: mul_a=t3  mul_b=t4   add_a=s1
//   CS3: mul_a=t5             add_a=s2
//   CS4:                      add_a=s3
//   CS5:                      add_a=out1
//
// Only one adder is active per step (the additions form a dependency
// chain), so the design stays within the 3-adder / 2-multiplier budget.
//
// Multi-cycle datapath with shared, time-multiplexed functional units
// controlled by a 5-state FSM.
//======================================================================

module iirb_hls #(
    parameter WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst,      // synchronous, active high
    input  wire                  start,    // pulse to latch inputs & begin
    input  wire [WIDTH-1:0]      in1,  in2,  in3,  in4,  in5,
    input  wire [WIDTH-1:0]      in6,  in7,  in8,  in9,  in10,
    output reg  [WIDTH-1:0]      out1,     // result
    output reg                   done      // high for one cycle when out1 valid
);

    // ------------------------------------------------------------------
    // FSM state encoding
    // ------------------------------------------------------------------
    localparam S_IDLE = 3'd0,
               S_CS1  = 3'd1,
               S_CS2  = 3'd2,
               S_CS3  = 3'd3,
               S_CS4  = 3'd4,
               S_CS5  = 3'd5;

    reg [2:0] state;

    // ------------------------------------------------------------------
    // Input registers (latched at start)
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] r1, r2, r3, r4, r5, r6, r7, r8, r9, r10;

    // ------------------------------------------------------------------
    // Intermediate value registers
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] t1, t2, t3, t4, t5;   // products
    reg [WIDTH-1:0] s1, s2, s3;           // partial sums

    // ------------------------------------------------------------------
    // Shared functional units (2 multipliers, 3 adders).
    // Inputs are steered by muxes that depend on the current state.
    // ------------------------------------------------------------------
    reg  [WIDTH-1:0] mul_a_x, mul_a_y;    // multiplier A operands
    reg  [WIDTH-1:0] mul_b_x, mul_b_y;    // multiplier B operands
    reg  [WIDTH-1:0] add_a_x, add_a_y;    // adder A operands

    wire [WIDTH-1:0] mul_a_o = mul_a_x * mul_a_y;   // truncated to WIDTH
    wire [WIDTH-1:0] mul_b_o = mul_b_x * mul_b_y;
    wire [WIDTH-1:0] add_a_o = add_a_x + add_a_y;

    // Note: products/sums are truncated to WIDTH bits. Widen WIDTH or the
    // FU output nets if full-precision (non-wrapping) results are required.

    // ------------------------------------------------------------------
    // Datapath input steering (combinational, per control step)
    // ------------------------------------------------------------------
    always @(*) begin
        // safe defaults
        mul_a_x = {WIDTH{1'b0}}; mul_a_y = {WIDTH{1'b0}};
        mul_b_x = {WIDTH{1'b0}}; mul_b_y = {WIDTH{1'b0}};
        add_a_x = {WIDTH{1'b0}}; add_a_y = {WIDTH{1'b0}};
        case (state)
            S_CS1: begin
                mul_a_x = r1; mul_a_y = r2;   // t1 = in1*in2
                mul_b_x = r3; mul_b_y = r4;   // t2 = in3*in4
            end
            S_CS2: begin
                mul_a_x = r5; mul_a_y = r6;   // t3 = in5*in6
                mul_b_x = r7; mul_b_y = r8;   // t4 = in7*in8
                add_a_x = t1; add_a_y = t2;   // s1 = t1+t2
            end
            S_CS3: begin
                mul_a_x = r9; mul_a_y = r10;  // t5 = in9*in10
                add_a_x = t3; add_a_y = s1;   // s2 = t3+s1
            end
            S_CS4: begin
                add_a_x = s2; add_a_y = t4;   // s3 = s2+t4
            end
            S_CS5: begin
                add_a_x = s3; add_a_y = t5;   // out1 = s3+t5
            end
            default: ; // hold defaults
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential control + register updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            out1  <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;               // default; pulsed in S_CS5
            case (state)
                S_IDLE: begin
                    if (start) begin
                        // latch inputs
                        r1<=in1; r2<=in2; r3<=in3; r4<=in4; r5<=in5;
                        r6<=in6; r7<=in7; r8<=in8; r9<=in9; r10<=in10;
                        state <= S_CS1;
                    end
                end

                S_CS1: begin
                    t1 <= mul_a_o;         // in1*in2
                    t2 <= mul_b_o;         // in3*in4
                    state <= S_CS2;
                end

                S_CS2: begin
                    t3 <= mul_a_o;         // in5*in6
                    t4 <= mul_b_o;         // in7*in8
                    s1 <= add_a_o;         // t1+t2
                    state <= S_CS3;
                end

                S_CS3: begin
                    t5 <= mul_a_o;         // in9*in10
                    s2 <= add_a_o;         // t3+s1
                    state <= S_CS4;
                end

                S_CS4: begin
                    s3 <= add_a_o;         // s2+t4
                    state <= S_CS5;
                end

                S_CS5: begin
                    out1 <= add_a_o;       // s3+t5
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
