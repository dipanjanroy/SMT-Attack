//======================================================================
// iirb_obfuscated_hls.v
//----------------------------------------------------------------------
// This is the obfuscated IIRB datapath. It has
// 37 key bits:
//   - key[1..30] : ten 8:1 primary-input muxes (3 key bits each), m1..m10
//   - key[31..37]: seven 2:1 node muxes, n1..n8
//
// With the correct key the design computes the IIRB function:
//   out1 = in1*in2 + in3*in4 + in5*in6 + in7*in8 + in9*in10
//
// Resource constraint : 2 multipliers, 3 adders
//   CS1: raw1=m1*m2  raw2=m3*m4                          (2 mul)
//   CS2: raw3=m5*m6  raw6=m7*m8   raw4=n1+n2             (2 mul, 1 add)
//   CS3: raw8=m9*m10              raw5=n3+n4             (1 mul, 1 add)
//   CS4:                          raw7=n5+n6             (1 add)
//   CS5:                          raw9=raw7+n8 -> out1   (1 add)
//
// Node muxes (combinational, key-controlled) are evaluated at the end of
// each control step and registered for use in later steps.
//======================================================================

module iirb_obfuscated_hls #(
    parameter WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst,      // synchronous, active high
    input  wire                  start,    // pulse to latch inputs & begin
    input  wire [37:1]           key,      // 37 obfuscation key bits
    input  wire [WIDTH-1:0]      in1,  in2,  in3,  in4,  in5,
    input  wire [WIDTH-1:0]      in6,  in7,  in8,  in9,  in10,
    output reg  [WIDTH-1:0]      out1,     // result
    output reg                   done      // high for one cycle when valid
);

    // ------------------------------------------------------------------
    // 8:1 mux helper.  sel = {kA,kB,kC} with kA the MSB, matching the
    // And(Not,..)/index encoding of the Python source.
    // ------------------------------------------------------------------
    function [WIDTH-1:0] mux8;
        input [2:0]        sel;
        input [WIDTH-1:0]  a0,a1,a2,a3,a4,a5,a6,a7;
        begin
            case (sel)
                3'd0: mux8 = a0;  3'd1: mux8 = a1;
                3'd2: mux8 = a2;  3'd3: mux8 = a3;
                3'd4: mux8 = a4;  3'd5: mux8 = a5;
                3'd6: mux8 = a6;  default: mux8 = a7;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // FSM state encoding
    // ------------------------------------------------------------------
    localparam S_IDLE = 3'd0, S_CS1 = 3'd1, S_CS2 = 3'd2,
               S_CS3  = 3'd3, S_CS4 = 3'd4, S_CS5 = 3'd5;
    reg [2:0] state;

    // ------------------------------------------------------------------
    // Latched primary inputs
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] r1,r2,r3,r4,r5,r6,r7,r8,r9,r10;

    // ------------------------------------------------------------------
    // Primary-input obfuscation muxes m1..m10 (combinational)
    // ------------------------------------------------------------------
    wire [WIDTH-1:0] m1  = mux8({key[1],  key[2],  key[3]},  r1,r2,r3,r4,r5,r6,r7,r8);
    wire [WIDTH-1:0] m2  = mux8({key[4],  key[5],  key[6]},  r2,r3,r4,r5,r6,r7,r8,r9);
    wire [WIDTH-1:0] m3  = mux8({key[7],  key[8],  key[9]},  r3,r4,r5,r6,r7,r8,r9,r10);
    wire [WIDTH-1:0] m4  = mux8({key[10], key[11], key[12]}, r4,r5,r6,r7,r8,r9,r10,r1);
    wire [WIDTH-1:0] m5  = mux8({key[13], key[14], key[15]}, r5,r6,r7,r8,r9,r10,r1,r2);
    wire [WIDTH-1:0] m6  = mux8({key[16], key[17], key[18]}, r6,r7,r8,r9,r10,r1,r2,r3);
    wire [WIDTH-1:0] m7  = mux8({key[19], key[20], key[21]}, r7,r8,r9,r10,r1,r2,r3,r4);
    wire [WIDTH-1:0] m8  = mux8({key[22], key[23], key[24]}, r8,r9,r10,r1,r2,r3,r4,r5);
    wire [WIDTH-1:0] m9  = mux8({key[25], key[26], key[27]}, r9,r10,r1,r2,r3,r4,r5,r6);
    wire [WIDTH-1:0] m10 = mux8({key[28], key[29], key[30]}, r10,r1,r2,r3,r4,r5,r6,r7);

    // ------------------------------------------------------------------
    // Registered node values passed between control steps
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] n1,n2,n3,n4,n5,n6,n8,raw7;

    // ------------------------------------------------------------------
    // Shared functional units (2 multipliers, 3 adders).
    // Only one adder is active per step, so the 3-adder budget is met.
    // ------------------------------------------------------------------
    reg  [WIDTH-1:0] mul_a_x, mul_a_y, mul_b_x, mul_b_y, add_a_x, add_a_y;
    wire [WIDTH-1:0] mul_a_o = mul_a_x * mul_a_y;   // truncated to WIDTH
    wire [WIDTH-1:0] mul_b_o = mul_b_x * mul_b_y;
    wire [WIDTH-1:0] add_a_o = add_a_x + add_a_y;

    // ------------------------------------------------------------------
    // Datapath operand steering per control step
    // ------------------------------------------------------------------
    always @(*) begin
        mul_a_x = {WIDTH{1'b0}}; mul_a_y = {WIDTH{1'b0}};
        mul_b_x = {WIDTH{1'b0}}; mul_b_y = {WIDTH{1'b0}};
        add_a_x = {WIDTH{1'b0}}; add_a_y = {WIDTH{1'b0}};
        case (state)
            S_CS1: begin
                mul_a_x = m1; mul_a_y = m2;    // raw1
                mul_b_x = m3; mul_b_y = m4;    // raw2
            end
            S_CS2: begin
                mul_a_x = m5; mul_a_y = m6;    // raw3
                mul_b_x = m7; mul_b_y = m8;    // raw6
                add_a_x = n1; add_a_y = n2;    // raw4 = n1+n2
            end
            S_CS3: begin
                mul_a_x = m9; mul_a_y = m10;   // raw8
                add_a_x = n3; add_a_y = n4;    // raw5 = n3+n4
            end
            S_CS4: begin
                add_a_x = n5; add_a_y = n6;    // raw7 = n5+n6
            end
            S_CS5: begin
                add_a_x = raw7; add_a_y = n8;  // raw9 = raw7+n8
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential control + node-mux evaluation
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            out1  <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        r1<=in1; r2<=in2; r3<=in3; r4<=in4; r5<=in5;
                        r6<=in6; r7<=in7; r8<=in8; r9<=in9; r10<=in10;
                        state <= S_CS1;
                    end
                end

                // CS1: raw1=m1*m2, raw2=m3*m4 ; n1,n2 muxes (keys 31,32)
                S_CS1: begin
                    n1 <= key[31] ? mul_b_o : mul_a_o;   // If(!k31,raw1,raw2)
                    n2 <= key[32] ? mul_a_o : mul_b_o;   // If(!k32,raw2,raw1)
                    state <= S_CS2;
                end

                // CS2: raw3=m5*m6, raw6=m7*m8, raw4=n1+n2
                //      n3,n6,n4 muxes (keys 33,34,35)
                S_CS2: begin
                    // raw3 = mul_a_o, raw6 = mul_b_o, raw4 = add_a_o
                    n3 <= key[33] ? mul_b_o : mul_a_o;   // If(!k33,raw3,raw6)
                    n6 <= key[34] ? add_a_o : mul_b_o;   // If(!k34,raw6,raw4)
                    n4 <= key[35] ? mul_a_o : add_a_o;   // If(!k35,raw4,raw3)
                    state <= S_CS3;
                end

                // CS3: raw8=m9*m10, raw5=n3+n4 ; n8,n5 muxes (keys 36,37)
                S_CS3: begin
                    // raw8 = mul_a_o, raw5 = add_a_o
                    n8 <= key[36] ? add_a_o : mul_a_o;   // If(!k36,raw8,raw5)
                    n5 <= key[37] ? mul_a_o : add_a_o;   // If(!k37,raw5,raw8)
                    state <= S_CS4;
                end

                // CS4: raw7 = n5 + n6
                S_CS4: begin
                    raw7 <= add_a_o;
                    state <= S_CS5;
                end

                // CS5: out1 = raw7 + n8
                S_CS5: begin
                    out1 <= add_a_o;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
