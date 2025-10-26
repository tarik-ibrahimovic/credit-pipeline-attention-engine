/*
 * Copyright (c) 2025 Tarik Ibrahimovic
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

/*
  MAC engine 4x4
 */
module tt_um_attention_top (
    input  wire [7:0] qv_slv_in,    // Dedicated inputs
    input  wire       vld_slv_in,
    output wire       rdy_slv_out,

    output wire [7:0] score_mst_out,   // Dedicated outputs
    output wire       vld_mst_out,
    input  wire       rdy_mst_in,

    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // // All output pins must be assigned. If not used, assign to 0.
  assign uio_oe [0] = 0; // vld_slv_in input
  assign uio_oe [1] = 1; // rdy_slv_out output

  assign uio_oe [2] = 1; // vld_mst_out output
  assign uio_oe [3] = 0; // rdy_mst_in input
  
  typedef enum reg [1:0] {
    FIRST  =  2'b00,
    WAIT4SECOND =  2'b01,
    READY  =  2'b10
  } input_reg_state_t;
  
  input_reg_state_t input_reg_state; 
  reg  input_reg; // one mult arg 
  
  wire [15:0] qv_mult = input_reg * qv_slv_in;
  reg [17:0]  mac_reg;

  assign rdy_slv_out = (input_reg_state == FIRST | input_reg_state == READY);

  always @(posedge clk) begin // input handshake + MULT
    if (rst_n == 1'b0) begin
      input_reg_state <= FIRST;
      mac_reg         <= 18'd0;
    end
    else begin
      case (input_reg_state)
        FIRST: begin
          if ({vld_slv_in, rdy_slv_out} == 2'b11) begin
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
          mac_reg <= (mac_reg + 18'(qv_mult));
        end
      endcase
    end
  end

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, clk, rst_n, 1'b0};

endmodule
