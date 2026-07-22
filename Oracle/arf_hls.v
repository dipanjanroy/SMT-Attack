//======================================================================
// arf_hls.v  (ORACLE, un-obfuscated)
//----------------------------------------------------------------------
// RTL from ARF_oracle.py.
//
//   t1..t8 = in(2k-1)*in(2k)              (8 mul)
//   s1=t1+t2  s2=t3+t4  s3=t5+t6  s4=t7+t8
//   s5=s1+s1  s6=s2+s2
//   s7=s5*s5  s8=s5*s5  s9=s6*s6  s10=s6*s6
//   s11=s7+s9 s12=s8+s10
//   s13=s11*s11 s14=s11*s11 s15=s12*s12 s16=s12*s12
//   s17=s13+s15 s18=s14+s16
//   out1=s17+s3   out2=s18+s4
//
// Resource constraint : 2 multipliers, 2 adders  ->  11 control steps.
//
//   S1 : t1=in1*in2    t2=in3*in4
//   S2 : t3=in5*in6    t4=in7*in8      | s1=t1+t2
//   S3 : t5=in9*in10   t6=in11*in12    | s2=t3+t4
//   S4 : t7=in13*in14  t8=in15*in16    | s5=s1+s1   s6=s2+s2
//   S5 : s7=s5*s5      s8=s5*s5        | s3=t5+t6   s4=t7+t8
//   S6 : s9=s6*s6      s10=s6*s6
//   S7 :                               | s11=s7+s9  s12=s8+s10
//   S8 : s13=s11*s11   s14=s11*s11
//   S9 : s15=s12*s12   s16=s12*s12
//   S10:                               | s17=s13+s15 s18=s14+s16
//   S11:                               | out1=s17+s3 out2=s18+s4
//======================================================================

module arf_hls #(
    parameter WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [WIDTH-1:0]      in1, in2, in3, in4, in5, in6, in7, in8,
    input  wire [WIDTH-1:0]      in9, in10, in11, in12, in13, in14, in15, in16,
    output reg  [WIDTH-1:0]      out1,
    output reg  [WIDTH-1:0]      out2,
    output reg                   done
);

    localparam [WIDTH-1:0] ZERO = {WIDTH{1'b0}};

    localparam S_IDLE=4'd0, S1=4'd1, S2=4'd2, S3=4'd3, S4=4'd4, S5=4'd5,
               S6=4'd6, S7=4'd7, S8=4'd8, S9=4'd9, S10=4'd10, S11=4'd11;
    reg [3:0] state;

    // Latched inputs
    reg [WIDTH-1:0] r1,r2,r3,r4,r5,r6,r7,r8,r9,r10,r11,r12,r13,r14,r15,r16;

    // Intermediate registers
    reg [WIDTH-1:0] t1,t2,t3,t4,t5,t6,t7,t8;
    reg [WIDTH-1:0] s1,s2,s3,s4,s5,s6,s7,s8,s9,s10;
    reg [WIDTH-1:0] s11,s12,s13,s14,s15,s16,s17,s18;

    // Shared functional units: 2 multipliers, 2 adders
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
                mul_a_x=r1;  mul_a_y=r2;   // t1
                mul_b_x=r3;  mul_b_y=r4;   // t2
            end
            S2: begin
                mul_a_x=r5;  mul_a_y=r6;   // t3
                mul_b_x=r7;  mul_b_y=r8;   // t4
                add_a_x=t1;  add_a_y=t2;   // s1
            end
            S3: begin
                mul_a_x=r9;  mul_a_y=r10;  // t5
                mul_b_x=r11; mul_b_y=r12;  // t6
                add_a_x=t3;  add_a_y=t4;   // s2
            end
            S4: begin
                mul_a_x=r13; mul_a_y=r14;  // t7
                mul_b_x=r15; mul_b_y=r16;  // t8
                add_a_x=s1;  add_a_y=s1;   // s5
                add_b_x=s2;  add_b_y=s2;   // s6
            end
            S5: begin
                mul_a_x=s5;  mul_a_y=s5;   // s7
                mul_b_x=s5;  mul_b_y=s5;   // s8
                add_a_x=t5;  add_a_y=t6;   // s3
                add_b_x=t7;  add_b_y=t8;   // s4
            end
            S6: begin
                mul_a_x=s6;  mul_a_y=s6;   // s9
                mul_b_x=s6;  mul_b_y=s6;   // s10
            end
            S7: begin
                add_a_x=s7;  add_a_y=s9;   // s11
                add_b_x=s8;  add_b_y=s10;  // s12
            end
            S8: begin
                mul_a_x=s11; mul_a_y=s11;  // s13
                mul_b_x=s11; mul_b_y=s11;  // s14
            end
            S9: begin
                mul_a_x=s12; mul_a_y=s12;  // s15
                mul_b_x=s12; mul_b_y=s12;  // s16
            end
            S10: begin
                add_a_x=s13; add_a_y=s15;  // s17
                add_b_x=s14; add_b_y=s16;  // s18
            end
            S11: begin
                add_a_x=s17; add_a_y=s3;   // out1
                add_b_x=s18; add_b_y=s4;   // out2
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
                S1:  begin t1<=mul_a_o; t2<=mul_b_o;                    state<=S2;  end
                S2:  begin t3<=mul_a_o; t4<=mul_b_o; s1<=add_a_o;       state<=S3;  end
                S3:  begin t5<=mul_a_o; t6<=mul_b_o; s2<=add_a_o;       state<=S4;  end
                S4:  begin t7<=mul_a_o; t8<=mul_b_o;
                           s5<=add_a_o; s6<=add_b_o;                    state<=S5;  end
                S5:  begin s7<=mul_a_o; s8<=mul_b_o;
                           s3<=add_a_o; s4<=add_b_o;                    state<=S6;  end
                S6:  begin s9<=mul_a_o; s10<=mul_b_o;                   state<=S7;  end
                S7:  begin s11<=add_a_o; s12<=add_b_o;                  state<=S8;  end
                S8:  begin s13<=mul_a_o; s14<=mul_b_o;                  state<=S9;  end
                S9:  begin s15<=mul_a_o; s16<=mul_b_o;                  state<=S10; end
                S10: begin s17<=add_a_o; s18<=add_b_o;                  state<=S11; end
                S11: begin out1<=add_a_o; out2<=add_b_o; done<=1'b1;    state<=S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
