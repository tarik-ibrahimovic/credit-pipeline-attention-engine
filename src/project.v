/*
 * Copyright (c) 2025 Tarik Ibrahimovic
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_attention_top (
    input  wire [7:0] ui_in,    // Q0.7 (-1,1-2^-7)
    output wire [7:0] uo_out,   

    input  wire [7:0] uio_in,   
    output wire [7:0] uio_out,  
    output wire [7:0] uio_oe,   
    
    input  wire       ena,      
    input  wire       clk,      
    input  wire       rst_n     
);
  // uio [0,1] used as slave vld/rdy
  // uio [2,3] used as master vld/rdy
    wire [7:0] qv_slv_in   = ui_in;
    
    wire [7:0] score_mst_out_w;
    // assign uo_out = sum_exs[7:0];
    
    wire vld_slv_in = uio_in[0];
    
    wire rdy_slv_out_w; 
    assign uio_out[1] = rdy_slv_out_w;
    
    wire vld_mst_out_w; 
    assign uio_out[2] = vld_mst_out_w;
    
    wire rdy_mst_in = uio_in[3];


    assign uio_oe [0] = 1'b0; 
    assign uio_oe [1] = 1'b1; 

    assign uio_oe [2] = 1'b1; 
    assign uio_oe [3] = 1'b0; 
    
    assign uio_oe [7:4] = 4'b0; 

    assign uio_out[0] = 1'b0; 
    assign uio_out[3] = 1'b0; 
    assign uio_out[7:4] = 4'b0; 
    
    assign vld_mst_out_w = 1'b0; 
    
    //-------------------------------------
    // MAC one row one column of 4 features
    //-------------------------------------
    typedef enum reg [1:0] {
      FIRST  =  2'b00,
      WAIT4SECOND =  2'b01,
      READY  =  2'b10
    } input_reg_state_t;
    
    input_reg_state_t input_reg_state; 
    reg signed  [7:0] input_reg; 
    
    wire signed [16:0] qv_mult = input_reg * $signed(qv_slv_in);
    reg signed [16:0]  mac_reg;

    assign rdy_slv_out_w = (input_reg_state == FIRST | input_reg_state == READY);
    assign score_mst_out_w = mac_div2[7:0]; 

    reg [1:0] count_mac;

    always @(posedge clk) begin 
      if (rst_n == 1'b0) begin
        input_reg_state <= FIRST;
        mac_reg         <= 17'd0;
        input_reg       <= 8'd0; 
        count_mac       <= 2'b0;
      end
      else begin
        case (input_reg_state)
          FIRST: begin
            if ({vld_slv_in, rdy_slv_out_w} == 2'b11) begin
              input_reg       <= qv_slv_in;
              input_reg_state <= WAIT4SECOND;
            end
          end
          WAIT4SECOND: begin
            if (vld_slv_in == 1'b1) begin
              input_reg_state <= READY;
            end
          end
          READY: begin
            mac_reg <= 17'(mac_reg + 17'(qv_mult));
            input_reg_state <= FIRST;
            count_mac <= count_mac + 1;
          end
          default: begin
          end
        endcase
      end
    end

    //----
    // e^x
    //----
    wire signed [8:0] ex_output;
    wire signed [16:0] mac_div2 = {mac_reg[16], mac_reg[16:1]}; // Q2.14 -> Q1.15
    wire signed [7:0] mac_reduced = mac_div2[16:9];
    ex u_ex (
      .mac_result(mac_reduced), // Q1.6
      .ex_result(ex_output) // UQ3.6
    );

    // Shift regs for e^x of each row member
    reg [1:0] count_ex; // count the number of rows done
    reg [8:0] ex_output_reg [4];
    always @(posedge clk) begin
      if(rst_n == 1'b0) begin
        count_ex <= 2'b0;
      end
      else begin
        if (input_reg_state == FIRST & count_mac == 2'h3 | count_ex == 2'd3 ) begin
          
          ex_output_reg[0] <= count_ex == 2'd3 ? ex_output[3] : ex_output;
          for (integer i = 0; i < 3; i++) begin
            ex_output_reg[i+1] <= ex_output_reg[i];
          end
          if(count_ex != 2'd3)
            count_ex <= count_ex + 1;
          if (count_acc == 2'd3) begin
            count_ex <= 2'd0;
          end
        end
      end
    end

    // sum everything after 4 inputs
    reg [10:0] sum_exs;
    reg [1:0] count_acc;
    always @(posedge clk) begin // 7.3*4 = 30  U5.6
      if (rst_n == 0) begin
        sum_exs <= 0;  
        count_acc <= 0;
      end 
      else begin
        if (count_ex == 2'd3) begin
          sum_exs <= sum_exs + ex_output_reg[3];
          count_acc <= count_acc + 1;
        end
        if (count_acc > 0) begin
          count_acc <= count_acc + 1;
          sum_exs <= sum_exs + ex_output_reg[3];  
        end
        if (count_acc == 2'd3) begin
          count_acc <= 2'd0;
        end
        
      end

    end

    // divide each by sum_ex and output
// ========= Reciprocal of Z = sum_exs (UQ5.6) and per-term division =========
// Assumes: sum_exs : [10:0] UQ5.6   (max < 32)
//          ex_output_reg[i] : [8:0] UQ3.6 (i=0..3)
// Outputs: uo_out : UQ0.8 (one weight per cycle)

reg        norm_start;
reg [1:0]  w_idx;               // which e_i we're outputting
reg        have_recip;

// 1) Leading-one detect for sum_exs (11 bits)
wire [10:0] Z = sum_exs;
wire [3:0]  msb =
    Z[10] ? 4'd10 :
    Z[9]  ? 4'd9  :
    Z[8]  ? 4'd8  :
    Z[7]  ? 4'd7  :
    Z[6]  ? 4'd6  :
    Z[5]  ? 4'd5  :
    Z[4]  ? 4'd4  :
    Z[3]  ? 4'd3  :
    Z[2]  ? 4'd2  :
    Z[1]  ? 4'd1  :
             4'd0;

// shift so that bit6 corresponds to "1.0" in Q?.6; target Z1 in [0.5,1) → [32..63]
wire signed [4:0] s = $signed({1'b0,msb}) - 5'sd6;
wire [10:0] Z1 = (s >= 0) ? (Z >>  s) : (Z << (-s));  // still UQ?.6, now 32..63

// 2) Convert Z1 to Q0.16
wire [21:0] Z1_q16 = {Z1, 10'b0}; // <<10

// 3) Reciprocal seed R0 ≈ 48/17 - (32/17)*Z1  on [0.5,1) (Q0.16)
localparam [17:0] C = 18'd185043;  // (48/17)*2^16
localparam [16:0] D = 17'd123362;  // (32/17)*2^16
wire [33:0] DZ   = $signed({1'b0,D}) * $signed({1'b0,Z1_q16}); // 17x22 -> 34
wire [17:0] R0   = $signed(C) - $signed(DZ[33:16]);            // Q0.16

// 4) One Newton step: R1 = R0 * (2 - Z1*R0)
wire [39:0] ZR0  = $signed({1'b0,Z1_q16}) * $signed({1'b0,R0}); // 22x18 -> 40
wire [17:0] T    = ZR0[39:22];                                  // Q0.16
wire [17:0] two  = 18'd131072;                                  // 2<<16
wire [17:0] corr = $signed(two) - $signed(T);
wire [35:0] R1_w = $signed({1'b0,R0}) * $signed({1'b0,corr});   // 18x18 -> 36
wire [17:0] R1   = R1_w[35:18];                                 // Q0.16

// 5) Undo normalization: 1/Z = R1 / 2^s
wire [17:0] R = (s >= 0) ? (R1 >> s) : (R1 << (-s));            // Q0.16

// 6) Multiply each e_i (UQ3.6) by R to get weights in Q0.16, then to UQ0.8
wire [18:0] e0_q16 = {ex_output_reg[0], 10'b0}; // <<10
wire [18:0] e1_q16 = {ex_output_reg[1], 10'b0};
wire [18:0] e2_q16 = {ex_output_reg[2], 10'b0};
wire [18:0] e3_q16 = {ex_output_reg[3], 10'b0};

wire [36:0] p0 = $signed({1'b0,e0_q16}) * $signed({1'b0,R}); // 19x18 -> 37
wire [36:0] p1 = $signed({1'b0,e1_q16}) * $signed({1'b0,R});
wire [36:0] p2 = $signed({1'b0,e2_q16}) * $signed({1'b0,R});
wire [36:0] p3 = $signed({1'b0,e3_q16}) * $signed({1'b0,R});

// Q0.16 results
wire [17:0] w0_q16 = p0[36:19];
wire [17:0] w1_q16 = p1[36:19];
wire [17:0] w2_q16 = p2[36:19];
wire [17:0] w3_q16 = p3[36:19];

// Quantize to UQ0.8: >>8 with saturation to 8 bits
function [7:0] q16_to_uq08;
  input [17:0] q16;
  begin
    if (|q16[17:16]) q16_to_uq08 = 8'hFF;       // >1.0 saturates
    else q16_to_uq08              = q16[15:8];  // >>8
  end
endfunction

reg [7:0] w_out;
always @(*) begin
  case (w_idx)
    2'd0: w_out = q16_to_uq08(w0_q16);
    2'd1: w_out = q16_to_uq08(w1_q16);
    2'd2: w_out = q16_to_uq08(w2_q16);
    default: w_out = q16_to_uq08(w3_q16);
  endcase
end

// Simple handoff: when sum_exs is ready (count_acc==3), stream 4 weights
always @(posedge clk) begin
  if (!rst_n) begin
    w_idx      <= 2'd0;
    norm_start <= 1'b0;
    have_recip <= 1'b0;
  end else begin
    // mark start when 4th term added into sum_exs (your logic)
    if (count_acc == 2'd3 && !norm_start) begin
      norm_start <= 1'b1;       // reciprocal ready next cycle (combinational)
      have_recip <= 1'b1;
      w_idx      <= 2'd0;
    end else if (have_recip) begin
      // output next weight each cycle
      w_idx <= w_idx + 1'b1;
      if (w_idx == 2'd3) begin
        have_recip <= 1'b0;     // done streaming 4 weights
        norm_start <= 1'b0;
      end
    end
  end
end

// Drive output bus with weights instead of sum (one per cycle when valid)
assign uo_out = have_recip ? w_out : 8'h00;


    wire _unused = &{ena, clk, rst_n, rdy_mst_in, uio_in[7:4], 1'b0};

endmodule