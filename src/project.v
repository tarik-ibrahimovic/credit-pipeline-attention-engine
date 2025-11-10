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

    //-------------------------------------
    // I/O mapping
    //-------------------------------------
    wire [7:0] qv_slv_in   = ui_in;

    wire vld_slv_in = uio_in[0];
    wire rdy_mst_in = uio_in[3];

    reg  vld_mst_out_w;
    wire rdy_slv_out_w;

    wire signed [8:0] ex_output;
    reg  signed [8:0] ex_output_reg; // latched output value

    // Assign outputs
    assign uo_out       = ex_output_reg[7:0];
    assign uio_out[4]   = ex_output_reg[8];
    assign uio_out[1]   = rdy_slv_out_w;
    assign uio_out[2]   = vld_mst_out_w;
    assign uio_out[0]   = 1'b0;
    assign uio_out[3]   = 1'b0;
    assign uio_out[7:5] = 3'b0;

    // Output enables
    assign uio_oe = 8'b00010110; // [4,2,1] outputs enabled

    //-------------------------------------
    // MAC one row × one column of 4 features
    //-------------------------------------
    typedef enum reg {
      FIRST        = 1'b0,
      WAIT4SECOND  = 1'b1
    } input_reg_state_t;

    input_reg_state_t input_reg_state;
    reg  signed [7:0]  input_reg;
    reg  signed [16:0] mac_reg;
    reg  [1:0]         count_mac;

    wire signed [16:0] qv_mult = input_reg * $signed(qv_slv_in);

    assign rdy_slv_out_w = 1'b1;

    reg done_mac;
    always @(posedge clk) begin
        if (rst_n == 1'b0) begin
            input_reg_state <= FIRST;
            mac_reg         <= 17'd0;
            input_reg       <= 8'd0;
            count_mac       <= 2'd0;
            done_mac        <= 1'd0;
        end else begin
            case (input_reg_state)
                FIRST: begin
                    if ( (vld_slv_in == 1'b1) && (rdy_slv_out_w == 1'b1) ) begin
                        input_reg       <= qv_slv_in;
                        input_reg_state <= WAIT4SECOND;
                        if (count_mac == 2'd0) begin
                            mac_reg <= 17'd0;
                            done_mac <= 1'b0;
                        end
                    end
                end
                WAIT4SECOND: begin
                    if (vld_slv_in == 1'b1) begin
                        input_reg_state <= FIRST;
                        mac_reg         <= mac_reg + qv_mult;
                        count_mac       <= count_mac + 1'b1;
                        if (count_mac == 2'd3)
                            done_mac <= 1'b1;
                    end
                end
                default: begin
                    input_reg_state <= FIRST;
                end
            endcase
        end
    end

    //-------------------------------------
    // e^x computation (UQ3.6)
    //-------------------------------------
    wire signed [16:0] mac_div2    = {mac_reg[16], mac_reg[16:1]}; // Q2.14 -> Q1.15
    wire signed [7:0]  mac_reduced = mac_div2[16:9];               // Q1.6

    ex u_ex (
        .mac_result(mac_reduced),
        .ex_result (ex_output)
    );

    //-------------------------------------
    // Output handshake and valid control
    //-------------------------------------
    always @(posedge clk) begin
        if (rst_n == 1'b0) begin
            vld_mst_out_w  <= 1'b0;
            ex_output_reg  <= 9'd0;
        end else begin
            // When 4th multiply done, latch exp() output and raise valid
            if ( done_mac == 1'b1 ) begin
                vld_mst_out_w <= 1'b1;
                ex_output_reg <= ex_output;
            end

            // Drop valid once master has acknowledged
            if ( (rdy_mst_in == 1'b1) && (vld_mst_out_w == 1'b1) ) begin
                vld_mst_out_w <= 1'b0;
            end
        end
    end

    //-------------------------------------
    // Unused signals (to avoid warnings)
    //-------------------------------------
    wire _unused = &{ena, clk, rst_n, uio_in[7:5], 1'b0};

endmodule
