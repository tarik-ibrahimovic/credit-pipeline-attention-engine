/*
 * Copyright (c) 2025 Tarik Ibrahimovic
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_attention_top (
    input  wire [7:0] ui_in,    
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
    assign uo_out = score_mst_out_w;
    
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
    assign score_mst_out_w = mac_reg[7:0]; 


    always @(posedge clk) begin 
      if (rst_n == 1'b0) begin
        input_reg_state <= FIRST;
        mac_reg         <= 17'd0;
        input_reg       <= 8'd0; 
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
          end
          default: begin
          end
        endcase
      end
    end

    //---------
    // Softmax
    //---------

    wire _unused = &{ena, clk, rst_n, rdy_mst_in, uio_in[7:4], 1'b0};

endmodule