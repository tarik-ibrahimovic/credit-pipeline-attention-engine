module ex (
    input  wire [7:0] mac_result,  // Q1.6 (signed)
    output wire [8:0] ex_result    // UQ3.6 (unsigned)
);
    // Alias
    wire signed [7:0] x = mac_result;  // Q1.6

    // ---- n ≈ round(x / ln2) using 92/64 (Q2.6) ----
    // Sign-extend x once to 16b, then do shifts there (avoids WIDTHEXPAND)
    wire signed [15:0] x_se   = {{8{x[7]}}, x};
    wire signed [15:0] mul92  = (x_se <<< 7) - (x_se <<< 5) - (x_se <<< 2); // 128-32-4 = 92*x
    wire signed [15:0] nq2_6  = mul92 >>> 6;                                // Q2.6

    // Round-to-nearest for signed Q2.6: add/sub 0.5 (=32) then >>>6
    wire signed [15:0] nq2_6_rnd = nq2_6 + (nq2_6[15] ? -16'sd32 : 16'sd32);
    // Take 3 LSBs of the integer after rounding (range about −3..+3)
    wire signed [2:0]  n_round   = 3'(nq2_6_rnd >>> 6);

   // r = x - n*ln2
    wire signed [9:0]  n_se  = {{7{n_round[2]}}, n_round};
    wire signed [9:0]  nL    = (n_se <<< 5) + (n_se <<< 3) + (n_se <<< 2); // n*44, Q1.6 units
    wire signed [8:0]  r_q16 = $signed({x[7], x}) - $signed(nL[8:0]);      // <-- truncates to 9b


    // ==== Polynomial in Q0.16: e^r ≈ 1 + r + r^2/2 ====
    // Convert r from Q1.6 -> Q0.16 by left shift of (16-6)=10
    wire signed [18:0] r_q0_16  = {{10{r_q16[8]}}, r_q16} <<< 10;          // 19b Q0.16

    // r^2: (Q0.16)^2 = Q0.32
    wire signed [37:0] r2_q0_32 = $signed(r_q0_16) * $signed(r_q0_16);
    // Downscale to Q0.16, then divide by 2 for (r^2)/2
    wire signed [21:0] r2_q0_16 = 22'(r2_q0_32 >>> 16);                          // 22b Q0.16
    wire signed [21:0] r2h_q0_16 = r2_q0_16 >>> 1;                          // (r^2)/2, Q0.16

    // Align widths to 22 bits and sum: 1 + r + r^2/2  (1.0 in Q0.16 = 65536)
    wire signed [21:0] one_q0_16 = 22'sd65536;
    wire signed [21:0] r_ext_q0_16 = {{(22-19){r_q0_16[18]}}, r_q0_16};     // extend 19b -> 22b
    wire signed [21:0] e_r_q0_16 = one_q0_16 + r_ext_q0_16 + r2h_q0_16;     // Q0.16, positive

    // ---- Apply 2^n via conditional shift (keep wide to avoid overflow) ----
    wire signed [31:0] e_r_wide = {{10{e_r_q0_16[21]}}, e_r_q0_16};         // 22b -> 32b
    wire signed [31:0] e_scaled_q0_16 =
        (n_round >= 0) ? (e_r_wide <<< n_round) : (e_r_wide >>> (-n_round));

    // ---- Q0.16 -> UQ3.6 (same 6 frac bits as Q1.6): right shift by (16-6)=10, clamp to 9 bits ----
    wire [31:0] uq36_pre = e_scaled_q0_16[31] ? 32'd0 : (e_scaled_q0_16 >>> 10); // unsigned magnitude
    wire [8:0]  e_sat    = (|uq36_pre[31:9]) ? 9'h1FF : uq36_pre[8:0];            // saturate to [0..511]

    assign ex_result = e_sat;  // UQ3.6
endmodule
