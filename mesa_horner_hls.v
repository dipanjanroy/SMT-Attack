//======================================================================
// mesa_horner_hls.v
//----------------------------------------------------------------------
// Oracle function:
//     t1=in1*in2; t2=in3*in4; t3=in5*in6; t4=in7*in8;
//     s1=t1+t1;   s2=t2+t2;   s3=t4+t4;
//     s4=s1*s1;   s5=s2*t3;   s6=s3*s3;
//     s7=s4+s4;   out1=s6+s6;
//     s9=s7*s7;
//     out2=s5+s9;
//
// Closed form:
//     out1 = 8*(in7*in8)^2
//     out2 = 2*(in3*in4)*(in5*in6) + 64*(in1*in2)^4
//
// Resource constraint : 4 multipliers, 3 adders
//
//   CS1: t1=in1*in2  t2=in3*in4  t3=in5*in6  t4=in7*in8   (4 mul)
//   CS2: s1=t1+t1    s2=t2+t2    s3=t4+t4                 (3 add)
//   CS3: s4=s1*s1    s5=s2*t3    s6=s3*s3                 (3 mul)
//   CS4: s7=s4+s4    out1=s6+s6                           (2 add)
//   CS5: s9=s7*s7                                         (1 mul)
//   CS6: out2=s5+s9                                       (1 add)
//
// Multi-cycle datapath with 4 shared multipliers + 3 shared adders,
// steered by a 6-state FSM.
//======================================================================

module mesa_horner_hls #(
    parameter WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst,      // synchronous, active high
    input  wire                  start,    // pulse to latch inputs & begin
    input  wire [WIDTH-1:0]      in1, in2, in3, in4, in5, in6, in7, in8,
    output reg  [WIDTH-1:0]      out1,
    output reg  [WIDTH-1:0]      out2,
    output reg                   done      // high for one cycle when valid
);

    // ------------------------------------------------------------------
    // FSM state encoding
    // ------------------------------------------------------------------
    localparam S_IDLE = 3'd0, S_CS1 = 3'd1, S_CS2 = 3'd2,
               S_CS3  = 3'd3, S_CS4 = 3'd4, S_CS5 = 3'd5, S_CS6 = 3'd6;
    reg [2:0] state;

    // ------------------------------------------------------------------
    // Latched primary inputs
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] r1,r2,r3,r4,r5,r6,r7,r8;

    // ------------------------------------------------------------------
    // Intermediate registers
    // ------------------------------------------------------------------
    reg [WIDTH-1:0] t1,t2,t3,t4;   // CS1 products
    reg [WIDTH-1:0] s1,s2,s3;      // CS2 sums
    reg [WIDTH-1:0] s4,s5,s6;      // CS3 products
    reg [WIDTH-1:0] s7;            // CS4 sum
    reg [WIDTH-1:0] s9;            // CS5 product

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
                mul_a_x=r1; mul_a_y=r2;   // t1=in1*in2
                mul_b_x=r3; mul_b_y=r4;   // t2=in3*in4
                mul_c_x=r5; mul_c_y=r6;   // t3=in5*in6
                mul_d_x=r7; mul_d_y=r8;   // t4=in7*in8
            end
            S_CS2: begin
                add_a_x=t1; add_a_y=t1;   // s1=t1+t1
                add_b_x=t2; add_b_y=t2;   // s2=t2+t2
                add_c_x=t4; add_c_y=t4;   // s3=t4+t4
            end
            S_CS3: begin
                mul_a_x=s1; mul_a_y=s1;   // s4=s1*s1
                mul_b_x=s2; mul_b_y=t3;   // s5=s2*t3
                mul_c_x=s3; mul_c_y=s3;   // s6=s3*s3
            end
            S_CS4: begin
                add_a_x=s4; add_a_y=s4;   // s7=s4+s4
                add_b_x=s6; add_b_y=s6;   // out1=s6+s6
            end
            S_CS5: begin
                mul_a_x=s7; mul_a_y=s7;   // s9=s7*s7
            end
            S_CS6: begin
                add_a_x=s5; add_a_y=s9;   // out2=s5+s9
            end
            default: ;
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

                S_CS1: begin
                    t1<=mul_a_o; t2<=mul_b_o; t3<=mul_c_o; t4<=mul_d_o;
                    state <= S_CS2;
                end

                S_CS2: begin
                    s1<=add_a_o; s2<=add_b_o; s3<=add_c_o;
                    state <= S_CS3;
                end

                S_CS3: begin
                    s4<=mul_a_o; s5<=mul_b_o; s6<=mul_c_o;
                    state <= S_CS4;
                end

                S_CS4: begin
                    s7   <= add_a_o;   // s7 = s4+s4
                    out1 <= add_b_o;   // out1 = s6+s6
                    state <= S_CS5;
                end

                S_CS5: begin
                    s9 <= mul_a_o;     // s9 = s7*s7
                    state <= S_CS6;
                end

                S_CS6: begin
                    out2 <= add_a_o;   // out2 = s5+s9
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule