//======================================================================
// arf_obfuscated_hls.v
//----------------------------------------------------------------------
// 83 key bits, 16 inputs (in1..in16), 2 outputs (out1,out2).
//   key[1..36]  : twelve 8:1 primary-input muxes (m1..m12), 3 keys each
//   key[37..42] : DEMUX keys (m5, n8, n10, n13, n14, n20)
//   key[43..81] : 2:1 / 4:1 node muxes
//   key[82,83]  : output 2:1 muxes (o1/o2 -> out1/out2)
//
// Resource constraint : 2 multipliers, 2 adders.
//
//   S1 : n1=m1*m2         n2=m3*m4
//   S2 : raw3=m5o0*m6     raw4=m7*m8      | D1=m5o1+m5o1  raw5=n1+n2
//   S3 : raw15=m9*m10     raw16=m11*m12   | raw6=n3+raw4  raw7=raw5+raw5
//   S4 : raw10=n7*n7      raw11=n7*n7     | raw8=n6+n6    raw23=n15+n16
//   S5 : raw9=n8o0*n8o0   raw12=n8o0*n8o0 | D2=n8o1+n8o1  D3=n10o1+n10o1
//   S6 : raw17=m13*m14    raw18=m15*m16   | raw13=n10+n9  raw14=n11+n12
//   S7 : raw20=n13o0^2    raw21=n13o0^2   | raw24=n17+n18 D4=n13o1+n13o1
//   S8 : raw19=n14o0^2    raw22=n14o0^2   | D5=n14o1+n14o1 D6=n20o1+n20o1
//   S9 : raw25=n20+n19    raw26=n21+n22
//   S10: raw27=raw25+n23  raw28=raw26+n24 -> o1,o2 -> out1,out2
//======================================================================

module arf_obfuscated_hls #(
    parameter WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [83:1]           key,
    input  wire [WIDTH-1:0]      in1, in2, in3, in4, in5, in6, in7, in8,
    input  wire [WIDTH-1:0]      in9, in10, in11, in12, in13, in14, in15, in16,
    output reg  [WIDTH-1:0]      out1,
    output reg  [WIDTH-1:0]      out2,
    output reg                   done
);

    // ------------------------------------------------------------------
    // Mux helpers.  sel MSB = first key of the group.
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

    localparam [WIDTH-1:0] ZERO = {WIDTH{1'b0}};

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam S_IDLE=4'd0, S1=4'd1, S2=4'd2, S3=4'd3, S4=4'd4, S5=4'd5,
               S6=4'd6, S7=4'd7, S8=4'd8, S9=4'd9, S10=4'd10;
    reg [3:0] state;

    // ------------------------------------------------------------------
    // Latched inputs
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] r1,r2,r3,r4,r5,r6,r7,r8,r9,r10,r11,r12,r13,r14,r15,r16;

    // ------------------------------------------------------------------
    // Registered datapath values
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] n1,n2, raw3,raw4,D1,raw5, raw15,raw16,raw6,raw7;
    reg [WIDTH-1:0] raw10,raw11,raw8,raw23, raw9,raw12,D2,D3;
    reg [WIDTH-1:0] raw17,raw18,raw13,raw14, raw20,raw21,raw24,D4;
    reg [WIDTH-1:0] raw19,raw22,D5,D6, raw25,raw26, raw27,raw28;

    // ------------------------------------------------------------------
    // Primary-input muxes m1..m16 (combinational)
    // ------------------------------------------------------------------
    wire [WIDTH-1:0] m1  = mux8({key[1], key[2], key[3]},  r1,r2,r3,r4,r5,r6,r7,r8);
    wire [WIDTH-1:0] m2  = mux8({key[4], key[5], key[6]},  r2,r3,r4,r5,r6,r7,r8,r9);
    wire [WIDTH-1:0] m3  = mux8({key[7], key[8], key[9]},  r3,r4,r5,r6,r7,r8,r9,r10);
    wire [WIDTH-1:0] m4  = mux8({key[10],key[11],key[12]}, r4,r5,r6,r7,r8,r9,r10,r11);
    wire [WIDTH-1:0] m5  = mux8({key[13],key[14],key[15]}, r5,r6,r7,r8,r9,r10,r11,r12);
    wire [WIDTH-1:0] m6  = mux8({key[16],key[17],key[18]}, r6,r7,r8,r9,r10,r11,r12,r1);
    wire [WIDTH-1:0] m7  = mux8({key[19],key[20],key[21]}, r7,r8,r9,r10,r11,r12,r1,r2);
    wire [WIDTH-1:0] m8  = mux8({key[22],key[23],key[24]}, r8,r9,r10,r11,r12,r1,r2,r3);
    wire [WIDTH-1:0] m9  = mux8({key[25],key[26],key[27]}, r9,r10,r11,r12,r1,r2,r3,r4);
    wire [WIDTH-1:0] m10 = mux8({key[28],key[29],key[30]}, r10,r11,r12,r1,r2,r3,r4,r5);
    wire [WIDTH-1:0] m11 = mux8({key[31],key[32],key[33]}, r11,r12,r1,r2,r3,r4,r5,r6);
    wire [WIDTH-1:0] m12 = mux8({key[34],key[35],key[36]}, r12,r1,r2,r3,r4,r5,r6,r7);
    wire [WIDTH-1:0] m13 = r13;
    wire [WIDTH-1:0] m14 = r14;
    wire [WIDTH-1:0] m15 = r15;
    wire [WIDTH-1:0] m16 = r16;

    // ------------------------------------------------------------------
    // DEMUX + node muxes (combinational, from registered raws)
    // ------------------------------------------------------------------
    wire [WIDTH-1:0] m5_out0 = key[37] ? ZERO : m5;
    wire [WIDTH-1:0] m5_out1 = key[37] ? m5   : ZERO;

    wire [WIDTH-1:0] n3 = key[43] ? D1 : raw3;    // If(!k43,raw3,D1)

    wire [WIDTH-1:0] n6  = mux4({key[44],key[45]}, raw6, raw7, raw15, raw16);
    wire [WIDTH-1:0] n7  = mux4({key[46],key[47]}, raw7, raw6, raw15, raw16);
    wire [WIDTH-1:0] n15 = mux4({key[48],key[49]}, raw15,raw6, raw7,  raw16);
    wire [WIDTH-1:0] n16 = mux4({key[50],key[51]}, raw16,raw6, raw7,  raw15);

    wire [WIDTH-1:0] n8  = mux4({key[52],key[53]}, raw8, raw10,raw11, raw23);
    wire [WIDTH-1:0] n10 = mux4({key[54],key[55]}, raw10,raw8, raw11, raw23);
    wire [WIDTH-1:0] n11 = mux4({key[56],key[57]}, raw11,raw8, raw10, raw23);
    wire [WIDTH-1:0] n23 = mux4({key[58],key[59]}, raw23,raw8, raw10, raw11);

    wire [WIDTH-1:0] n8_out0  = key[38] ? ZERO : n8;
    wire [WIDTH-1:0] n8_out1  = key[38] ? n8   : ZERO;
    wire [WIDTH-1:0] n10_out1 = key[39] ? n10  : ZERO;

    wire [WIDTH-1:0] n9  = mux4({key[60],key[61]}, raw9, raw12, D2, D3);
    wire [WIDTH-1:0] n12 = mux4({key[62],key[63]}, raw12,raw9,  D2, D3);

    wire [WIDTH-1:0] n13 = mux4({key[64],key[65]}, raw13,raw14,raw17,raw18);
    wire [WIDTH-1:0] n14 = mux4({key[66],key[67]}, raw14,raw13,raw17,raw18);
    wire [WIDTH-1:0] n17 = mux4({key[68],key[69]}, raw17,raw13,raw14,raw18);
    wire [WIDTH-1:0] n18 = mux4({key[70],key[71]}, raw18,raw13,raw14,raw17);

    wire [WIDTH-1:0] n13_out0 = key[40] ? ZERO : n13;
    wire [WIDTH-1:0] n13_out1 = key[40] ? n13  : ZERO;

    wire [WIDTH-1:0] n20 = mux4({key[72],key[73]}, raw20,raw21,raw24,D4);
    wire [WIDTH-1:0] n21 = mux4({key[74],key[75]}, raw21,raw20,raw24,D4);
    wire [WIDTH-1:0] n24 = mux4({key[76],key[77]}, raw24,raw20,raw21,D4);

    wire [WIDTH-1:0] n14_out0 = key[41] ? ZERO : n14;
    wire [WIDTH-1:0] n14_out1 = key[41] ? n14  : ZERO;
    wire [WIDTH-1:0] n20_out1 = key[42] ? n20  : ZERO;

    wire [WIDTH-1:0] n19 = mux4({key[78],key[79]}, raw19,raw22,D5,D6);
    wire [WIDTH-1:0] n22 = mux4({key[80],key[81]}, raw22,raw19,D5,D6);

    // ------------------------------------------------------------------
    // Shared functional units: 2 multipliers, 2 adders
    // ------------------------------------------------------------------
    reg  [WIDTH-1:0] mul_a_x,mul_a_y, mul_b_x,mul_b_y;
    reg  [WIDTH-1:0] add_a_x,add_a_y, add_b_x,add_b_y;
    wire [WIDTH-1:0] mul_a_o = mul_a_x * mul_a_y;
    wire [WIDTH-1:0] mul_b_o = mul_b_x * mul_b_y;
    wire [WIDTH-1:0] add_a_o = add_a_x + add_a_y;
    wire [WIDTH-1:0] add_b_o = add_b_x + add_b_y;

    // ------------------------------------------------------------------
    // Operand steering per control step
    // ------------------------------------------------------------------
    always @(*) begin
        mul_a_x=ZERO; mul_a_y=ZERO; mul_b_x=ZERO; mul_b_y=ZERO;
        add_a_x=ZERO; add_a_y=ZERO; add_b_x=ZERO; add_b_y=ZERO;
        case (state)
            S1: begin
                mul_a_x=m1;      mul_a_y=m2;       // n1
                mul_b_x=m3;      mul_b_y=m4;       // n2
            end
            S2: begin
                mul_a_x=m5_out0; mul_a_y=m6;       // raw3
                mul_b_x=m7;      mul_b_y=m8;       // raw4
                add_a_x=m5_out1; add_a_y=m5_out1;  // D1
                add_b_x=n1;      add_b_y=n2;       // raw5
            end
            S3: begin
                mul_a_x=m9;      mul_a_y=m10;      // raw15
                mul_b_x=m11;     mul_b_y=m12;      // raw16
                add_a_x=n3;      add_a_y=raw4;     // raw6
                add_b_x=raw5;    add_b_y=raw5;     // raw7
            end
            S4: begin
                mul_a_x=n7;      mul_a_y=n7;       // raw10
                mul_b_x=n7;      mul_b_y=n7;       // raw11
                add_a_x=n6;      add_a_y=n6;       // raw8
                add_b_x=n15;     add_b_y=n16;      // raw23
            end
            S5: begin
                mul_a_x=n8_out0; mul_a_y=n8_out0;  // raw9
                mul_b_x=n8_out0; mul_b_y=n8_out0;  // raw12
                add_a_x=n8_out1; add_a_y=n8_out1;  // D2
                add_b_x=n10_out1;add_b_y=n10_out1; // D3
            end
            S6: begin
                mul_a_x=m13;     mul_a_y=m14;      // raw17
                mul_b_x=m15;     mul_b_y=m16;      // raw18
                add_a_x=n10;     add_a_y=n9;       // raw13
                add_b_x=n11;     add_b_y=n12;      // raw14
            end
            S7: begin
                mul_a_x=n13_out0;mul_a_y=n13_out0; // raw20
                mul_b_x=n13_out0;mul_b_y=n13_out0; // raw21
                add_a_x=n17;     add_a_y=n18;      // raw24
                add_b_x=n13_out1;add_b_y=n13_out1; // D4
            end
            S8: begin
                mul_a_x=n14_out0;mul_a_y=n14_out0; // raw19
                mul_b_x=n14_out0;mul_b_y=n14_out0; // raw22
                add_a_x=n14_out1;add_a_y=n14_out1; // D5
                add_b_x=n20_out1;add_b_y=n20_out1; // D6
            end
            S9: begin
                add_a_x=n20;     add_a_y=n19;      // raw25
                add_b_x=n21;     add_b_y=n22;      // raw26
            end
            S10: begin
                add_a_x=raw25;   add_a_y=n23;      // raw27
                add_b_x=raw26;   add_b_y=n24;      // raw28
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential control + register updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0; out1 <= ZERO; out2 <= ZERO;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    r1<=in1;   r2<=in2;   r3<=in3;   r4<=in4;
                    r5<=in5;   r6<=in6;   r7<=in7;   r8<=in8;
                    r9<=in9;   r10<=in10; r11<=in11; r12<=in12;
                    r13<=in13; r14<=in14; r15<=in15; r16<=in16;
                    state <= S1;
                end
                S1:  begin n1<=mul_a_o; n2<=mul_b_o;                      state<=S2;  end
                S2:  begin raw3<=mul_a_o; raw4<=mul_b_o;
                           D1<=add_a_o;   raw5<=add_b_o;                  state<=S3;  end
                S3:  begin raw15<=mul_a_o; raw16<=mul_b_o;
                           raw6<=add_a_o;  raw7<=add_b_o;                 state<=S4;  end
                S4:  begin raw10<=mul_a_o; raw11<=mul_b_o;
                           raw8<=add_a_o;  raw23<=add_b_o;                state<=S5;  end
                S5:  begin raw9<=mul_a_o;  raw12<=mul_b_o;
                           D2<=add_a_o;    D3<=add_b_o;                   state<=S6;  end
                S6:  begin raw17<=mul_a_o; raw18<=mul_b_o;
                           raw13<=add_a_o; raw14<=add_b_o;                state<=S7;  end
                S7:  begin raw20<=mul_a_o; raw21<=mul_b_o;
                           raw24<=add_a_o; D4<=add_b_o;                   state<=S8;  end
                S8:  begin raw19<=mul_a_o; raw22<=mul_b_o;
                           D5<=add_a_o;    D6<=add_b_o;                   state<=S9;  end
                S9:  begin raw25<=add_a_o; raw26<=add_b_o;               state<=S10; end
                S10: begin
                    raw27<=add_a_o; raw28<=add_b_o;
                    // o1=raw27, o2=raw28 ; output 2:1 muxes (key82,key83)
                    out1 <= key[82] ? add_b_o : add_a_o;   // If(!k82,o1,o2)
                    out2 <= key[83] ? add_a_o : add_b_o;   // If(!k83,o2,o1)
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
