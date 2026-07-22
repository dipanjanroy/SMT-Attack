//======================================================================
// iirb_shield_obfuscated_hls.v
//----------------------------------------------------------------------
//
// 21 key bits, 10 inputs (in1..in10), 1 output (out1).
//   key[1..10]  : five 4:1 primary-input muxes (m1..m5), 2 keys each
//   key[11,12]  : CS1 DEMUX (m1, m2)
//   key[13]     : CS3 DEMUX (raw3)
//   key[14]     : CS4 DEMUX (n5)
//   key[15..18] : CS1 4:1 node muxes (n1, n2)
//   key[19,20]  : CS3 2:1 node muxes (n5, n8)
//   key[21]     : CS4 2:1 node mux (n7)
//
// Resource constraint : 2 multipliers, 3 adders
// ASAP schedule       : 5 control steps
//
//   CS1: raw1=m1o0*m2o0  raw2=m3*m4  | D1=m1o1+m1o1  D2=m2o1+m2o1
//   CS2: raw3=m5*m6      raw6=m7*m8  | raw4=n1+n2
//   CS3: raw8=m9*m10                 | raw5=raw3o0+raw4  D3=raw3o1+raw3o1
//   CS4:                             | raw7=n5o0+raw6    D4=n5o1+n5o1
//   CS5:                             | raw9=n7+n8  -> out1
//======================================================================

module iirb_shield_obfuscated_hls #(
    parameter WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [21:1]           key,
    input  wire [WIDTH-1:0]      in1, in2, in3, in4, in5,
    input  wire [WIDTH-1:0]      in6, in7, in8, in9, in10,
    output reg  [WIDTH-1:0]      out1,
    output reg                   done
);

    function [WIDTH-1:0] mux4;
        input [1:0]        sel;
        input [WIDTH-1:0]  a0,a1,a2,a3;
        begin
            case (sel)
                2'd0: mux4=a0; 2'd1: mux4=a1; 2'd2: mux4=a2; default: mux4=a3;
            endcase
        end
    endfunction

    localparam [WIDTH-1:0] ZERO = {WIDTH{1'b0}};

    localparam S_IDLE=3'd0, S1=3'd1, S2=3'd2, S3=3'd3, S4=3'd4, S5=3'd5;
    reg [2:0] state;

    // Latched inputs
    reg [WIDTH-1:0] r1,r2,r3,r4,r5,r6,r7,r8,r9,r10;

    // Registered datapath values
    reg [WIDTH-1:0] raw1, raw2, D1, D2;   // CS1
    reg [WIDTH-1:0] raw3, raw6, raw4;     // CS2
    reg [WIDTH-1:0] raw8, raw5, D3;       // CS3
    reg [WIDTH-1:0] raw7, D4;             // CS4

    // Primary-input muxes m1..m10 (combinational)
    wire [WIDTH-1:0] m1  = mux4({key[1], key[2]},  r1,r2,r3,r4);
    wire [WIDTH-1:0] m2  = mux4({key[3], key[4]},  r2,r3,r4,r5);
    wire [WIDTH-1:0] m3  = mux4({key[5], key[6]},  r3,r4,r5,r1);
    wire [WIDTH-1:0] m4  = mux4({key[7], key[8]},  r4,r5,r1,r2);
    wire [WIDTH-1:0] m5  = mux4({key[9], key[10]}, r5,r1,r2,r3);
    wire [WIDTH-1:0] m6  = r6;
    wire [WIDTH-1:0] m7  = r7;
    wire [WIDTH-1:0] m8  = r8;
    wire [WIDTH-1:0] m9  = r9;
    wire [WIDTH-1:0] m10 = r10;

    // CS1 DEMUX on m1, m2
    wire [WIDTH-1:0] m1_out0 = key[11] ? ZERO : m1;
    wire [WIDTH-1:0] m1_out1 = key[11] ? m1   : ZERO;
    wire [WIDTH-1:0] m2_out0 = key[12] ? ZERO : m2;
    wire [WIDTH-1:0] m2_out1 = key[12] ? m2   : ZERO;

    // CS1 4:1 node muxes n1, n2  (from CS1 registers)
    wire [WIDTH-1:0] n1 = mux4({key[15],key[16]}, raw1, raw2, D1, D2);
    wire [WIDTH-1:0] n2 = mux4({key[17],key[18]}, raw2, raw1, D1, D2);

    // CS3 DEMUX on raw3
    wire [WIDTH-1:0] raw3_out0 = key[13] ? ZERO : raw3;
    wire [WIDTH-1:0] raw3_out1 = key[13] ? raw3 : ZERO;

    // CS3 2:1 node muxes n5, n8  (from CS3 registers)
    wire [WIDTH-1:0] n5 = key[19] ? D3 : raw5;   // If(!k19,raw5,D3)
    wire [WIDTH-1:0] n8 = key[20] ? D3 : raw8;   // If(!k20,raw8,D3)

    // CS4 DEMUX on n5
    wire [WIDTH-1:0] n5_out0 = key[14] ? ZERO : n5;
    wire [WIDTH-1:0] n5_out1 = key[14] ? n5   : ZERO;

    // CS4 2:1 node mux n7  (from CS4 registers)
    wire [WIDTH-1:0] n7 = key[21] ? D4 : raw7;   // If(!k21,raw7,D4)

    // Shared functional units: 2 multipliers, 3 adders
    reg  [WIDTH-1:0] mul_a_x,mul_a_y, mul_b_x,mul_b_y;
    reg  [WIDTH-1:0] add_a_x,add_a_y, add_b_x,add_b_y, add_c_x,add_c_y;
    wire [WIDTH-1:0] mul_a_o = mul_a_x * mul_a_y;
    wire [WIDTH-1:0] mul_b_o = mul_b_x * mul_b_y;
    wire [WIDTH-1:0] add_a_o = add_a_x + add_a_y;
    wire [WIDTH-1:0] add_b_o = add_b_x + add_b_y;
    wire [WIDTH-1:0] add_c_o = add_c_x + add_c_y;   // spare adder (budget = 3)

    always @(*) begin
        mul_a_x=ZERO; mul_a_y=ZERO; mul_b_x=ZERO; mul_b_y=ZERO;
        add_a_x=ZERO; add_a_y=ZERO; add_b_x=ZERO; add_b_y=ZERO;
        add_c_x=ZERO; add_c_y=ZERO;
        case (state)
            S1: begin
                mul_a_x=m1_out0; mul_a_y=m2_out0;  // raw1
                mul_b_x=m3;      mul_b_y=m4;       // raw2
                add_a_x=m1_out1; add_a_y=m1_out1;  // D1
                add_b_x=m2_out1; add_b_y=m2_out1;  // D2
            end
            S2: begin
                mul_a_x=m5;      mul_a_y=m6;       // raw3
                mul_b_x=m7;      mul_b_y=m8;       // raw6
                add_a_x=n1;      add_a_y=n2;       // raw4
            end
            S3: begin
                mul_a_x=m9;        mul_a_y=m10;      // raw8
                add_a_x=raw3_out0; add_a_y=raw4;     // raw5
                add_b_x=raw3_out1; add_b_y=raw3_out1;// D3
            end
            S4: begin
                add_a_x=n5_out0; add_a_y=raw6;     // raw7
                add_b_x=n5_out1; add_b_y=n5_out1;  // D4
            end
            S5: begin
                add_a_x=n7;      add_a_y=n8;       // raw9
            end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0; out1 <= ZERO;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    r1<=in1; r2<=in2; r3<=in3; r4<=in4; r5<=in5;
                    r6<=in6; r7<=in7; r8<=in8; r9<=in9; r10<=in10;
                    state <= S1;
                end
                S1: begin raw1<=mul_a_o; raw2<=mul_b_o;
                          D1<=add_a_o;   D2<=add_b_o;             state<=S2; end
                S2: begin raw3<=mul_a_o; raw6<=mul_b_o;
                          raw4<=add_a_o;                          state<=S3; end
                S3: begin raw8<=mul_a_o;
                          raw5<=add_a_o; D3<=add_b_o;             state<=S4; end
                S4: begin raw7<=add_a_o; D4<=add_b_o;             state<=S5; end
                S5: begin out1<=add_a_o; done<=1'b1;             state<=S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
