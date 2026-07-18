//======================================================================
// mesa_horner_obfuscated_hls.v
//----------------------------------------------------------------------
// RTL generated from PROTECT_MESA_HORNER_Obfuscated.py via HLS.
//
// PROTECT-obfuscated (logic-locked) MESA/Horner datapath, 40 key bits:
//   - key[1..24] : eight 8:1 primary-input muxes (3 bits each), m1..m8
//   - key[25..32]: four 4:1 node muxes (2 bits each),  n1..n4
//   - key[33..40]: eight 2:1 node muxes,               n5..n13
//
// With the correct key the design computes the MESA/Horner function:
//   out1 = 8*(in7*in8)^2
//   out2 = 2*(in3*in4)*(in5*in6) + 64*(in1*in2)^4
//
// Resource constraint : 4 multipliers, 3 adders
// ASAP schedule       : 6 control steps (matches CS1..CS6 in the source)
//
//   CS1: raw1=m1*m2 raw2=m3*m4 raw3=m5*m6 raw4=m7*m8   (4 mul)
//   CS2: raw5=n1+n1 raw6=n2+n2 raw7=n4+n4              (3 add)
//   CS3: raw9=n5*n5 raw8=n6*n3 raw10=n7*n7             (3 mul)
//   CS4: raw11=n9+n9 raw13=n10+n10                     (2 add)
//   CS5: raw12=n11*n11                                 (1 mul)
//   CS6: raw14=n8+raw12                                (1 add)
//   outputs: o1 = n13 ,  o2 = raw14
//======================================================================

module mesa_horner_obfuscated_hls #(
    parameter WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst,      // synchronous, active high
    input  wire                  start,    // pulse to latch inputs & begin
    input  wire [40:1]           key,      // 40 obfuscation key bits
    input  wire [WIDTH-1:0]      in1, in2, in3, in4, in5, in6, in7, in8,
    output reg  [WIDTH-1:0]      out1,     // o1
    output reg  [WIDTH-1:0]      out2,     // o2
    output reg                   done      // high for one cycle when valid
);

    // ------------------------------------------------------------------
    // Mux helpers.  sel MSB is the first key of the group, matching the
    // And(Not,..)/index encoding of the Python source.
    // ------------------------------------------------------------------
    function [WIDTH-1:0] mux8;
        input [2:0]        sel;
        input [WIDTH-1:0]  a0,a1,a2,a3,a4,a5,a6,a7;
        begin
            case (sel)
                3'd0: mux8=a0; 3'd1: mux8=a1; 3'd2: mux8=a2; 3'd3: mux8=a3;
                3'd4: mux8=a4; 3'd5: mux8=a5; 3'd6: mux8=a6; default: mux8=a7;
            endcase
        end
    endfunction

    function [WIDTH-1:0] mux4;
        input [1:0]        sel;
        input [WIDTH-1:0]  a0,a1,a2,a3;
        begin
            case (sel)
                2'd0: mux4=a0; 2'd1: mux4=a1; 2'd2: mux4=a2; default: mux4=a3;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // FSM state encoding
    // ------------------------------------------------------------------
    localparam S_IDLE=3'd0, S_CS1=3'd1, S_CS2=3'd2,
               S_CS3=3'd3, S_CS4=3'd4, S_CS5=3'd5, S_CS6=3'd6;
    reg [2:0] state;

    // ------------------------------------------------------------------
    // Latched primary inputs
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] r1,r2,r3,r4,r5,r6,r7,r8;

    // ------------------------------------------------------------------
    // Primary-input obfuscation muxes m1..m8 (combinational)
    // ------------------------------------------------------------------
    wire [WIDTH-1:0] m1 = mux8({key[1], key[2], key[3]},  r1,r2,r3,r4,r5,r6,r7,r8);
    wire [WIDTH-1:0] m2 = mux8({key[4], key[5], key[6]},  r2,r3,r4,r5,r6,r7,r8,r1);
    wire [WIDTH-1:0] m3 = mux8({key[7], key[8], key[9]},  r3,r4,r5,r6,r7,r8,r1,r2);
    wire [WIDTH-1:0] m4 = mux8({key[10],key[11],key[12]}, r4,r5,r6,r7,r8,r1,r2,r3);
    wire [WIDTH-1:0] m5 = mux8({key[13],key[14],key[15]}, r5,r6,r7,r8,r1,r2,r3,r4);
    wire [WIDTH-1:0] m6 = mux8({key[16],key[17],key[18]}, r6,r7,r8,r1,r2,r3,r4,r5);
    wire [WIDTH-1:0] m7 = mux8({key[19],key[20],key[21]}, r7,r8,r1,r2,r3,r4,r5,r6);
    wire [WIDTH-1:0] m8 = mux8({key[22],key[23],key[24]}, r8,r1,r2,r3,r4,r5,r6,r7);

    // ------------------------------------------------------------------
    // Registered node values passed between control steps
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] n1,n2,n3,n4;     // from CS1
    reg [WIDTH-1:0] n5,n6,n7;        // from CS2
    reg [WIDTH-1:0] n8,n9,n10;       // from CS3
    reg [WIDTH-1:0] n11;             // from CS4
    reg [WIDTH-1:0] raw12;           // from CS5

    // ------------------------------------------------------------------
    // Shared functional units: 4 multipliers, 3 adders
    // ------------------------------------------------------------------
    reg  [WIDTH-1:0] mul_a_x,mul_a_y, mul_b_x,mul_b_y,
                     mul_c_x,mul_c_y, mul_d_x,mul_d_y;
    reg  [WIDTH-1:0] add_a_x,add_a_y, add_b_x,add_b_y, add_c_x,add_c_y;

    wire [WIDTH-1:0] mul_a_o = mul_a_x * mul_a_y;   // truncated to WIDTH
    wire [WIDTH-1:0] mul_b_o = mul_b_x * mul_b_y;
    wire [WIDTH-1:0] mul_c_o = mul_c_x * mul_c_y;
    wire [WIDTH-1:0] mul_d_o = mul_d_x * mul_d_y;
    wire [WIDTH-1:0] add_a_o = add_a_x + add_a_y;
    wire [WIDTH-1:0] add_b_o = add_b_x + add_b_y;
    wire [WIDTH-1:0] add_c_o = add_c_x + add_c_y;

    // ------------------------------------------------------------------
    // Operand steering per control step
    // ------------------------------------------------------------------
    always @(*) begin
        mul_a_x={WIDTH{1'b0}}; mul_a_y={WIDTH{1'b0}};
        mul_b_x={WIDTH{1'b0}}; mul_b_y={WIDTH{1'b0}};
        mul_c_x={WIDTH{1'b0}}; mul_c_y={WIDTH{1'b0}};
        mul_d_x={WIDTH{1'b0}}; mul_d_y={WIDTH{1'b0}};
        add_a_x={WIDTH{1'b0}}; add_a_y={WIDTH{1'b0}};
        add_b_x={WIDTH{1'b0}}; add_b_y={WIDTH{1'b0}};
        add_c_x={WIDTH{1'b0}}; add_c_y={WIDTH{1'b0}};
        case (state)
            S_CS1: begin
                mul_a_x=m1; mul_a_y=m2;   // raw1
                mul_b_x=m3; mul_b_y=m4;   // raw2
                mul_c_x=m5; mul_c_y=m6;   // raw3
                mul_d_x=m7; mul_d_y=m8;   // raw4
            end
            S_CS2: begin
                add_a_x=n1; add_a_y=n1;   // raw5 = n1+n1
                add_b_x=n2; add_b_y=n2;   // raw6 = n2+n2
                add_c_x=n4; add_c_y=n4;   // raw7 = n4+n4
            end
            S_CS3: begin
                mul_a_x=n5; mul_a_y=n5;   // raw9  = n5*n5
                mul_b_x=n6; mul_b_y=n3;   // raw8  = n6*n3
                mul_c_x=n7; mul_c_y=n7;   // raw10 = n7*n7
            end
            S_CS4: begin
                add_a_x=n9;  add_a_y=n9;  // raw11 = n9+n9
                add_b_x=n10; add_b_y=n10; // raw13 = n10+n10
            end
            S_CS5: begin
                mul_a_x=n11; mul_a_y=n11; // raw12 = n11*n11
            end
            S_CS6: begin
                add_a_x=n8; add_a_y=raw12; // raw14 = n8+raw12
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
            out2  <= {WIDTH{1'b0}};
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        r1<=in1; r2<=in2; r3<=in3; r4<=in4;
                        r5<=in5; r6<=in6; r7<=in7; r8<=in8;
                        state <= S_CS1;
                    end
                end

                // CS1: raw1..raw4 ; 4:1 node muxes n1..n4 (keys 25..32)
                S_CS1: begin
                    // raw1=mul_a_o raw2=mul_b_o raw3=mul_c_o raw4=mul_d_o
                    n1 <= mux4({key[25],key[26]}, mul_a_o,mul_b_o,mul_c_o,mul_d_o);
                    n2 <= mux4({key[27],key[28]}, mul_b_o,mul_c_o,mul_d_o,mul_a_o);
                    n3 <= mux4({key[29],key[30]}, mul_c_o,mul_d_o,mul_a_o,mul_b_o);
                    n4 <= mux4({key[31],key[32]}, mul_d_o,mul_a_o,mul_b_o,mul_c_o);
                    state <= S_CS2;
                end

                // CS2: raw5,raw6,raw7 ; 2:1 node muxes n5,n6,n7 (keys 33,34,35)
                S_CS2: begin
                    // raw5=add_a_o raw6=add_b_o raw7=add_c_o
                    n5 <= key[33] ? add_b_o : add_a_o;   // If(!k33,raw5,raw6)
                    n6 <= key[34] ? add_c_o : add_b_o;   // If(!k34,raw6,raw7)
                    n7 <= key[35] ? add_a_o : add_c_o;   // If(!k35,raw7,raw5)
                    state <= S_CS3;
                end

                // CS3: raw9,raw8,raw10 ; node muxes n9,n8,n10 (keys 36,37,38)
                S_CS3: begin
                    // raw9=mul_a_o raw8=mul_b_o raw10=mul_c_o
                    n9  <= key[36] ? mul_b_o : mul_a_o;  // If(!k36,raw9,raw8)
                    n8  <= key[37] ? mul_c_o : mul_b_o;  // If(!k37,raw8,raw10)
                    n10 <= key[38] ? mul_a_o : mul_c_o;  // If(!k38,raw10,raw9)
                    state <= S_CS4;
                end

                // CS4: raw11,raw13 ; node muxes n11,n13 (keys 39,40)
                S_CS4: begin
                    // raw11=add_a_o raw13=add_b_o
                    n11  <= key[39] ? add_b_o : add_a_o; // If(!k39,raw11,raw13)
                    out1 <= key[40] ? add_a_o : add_b_o; // n13 = If(!k40,raw13,raw11)
                    state <= S_CS5;
                end

                // CS5: raw12 = n11*n11
                S_CS5: begin
                    raw12 <= mul_a_o;
                    state <= S_CS6;
                end

                // CS6: out2 = n8 + raw12
                S_CS6: begin
                    out2 <= add_a_o;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
