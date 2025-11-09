module ex (
    input  wire [7:0] mac_result,  // Q1.6
    output wire [8:0] ex_result    // UQ3.6
);
    // Alias
    wire signed [7:0] x = mac_result;  // Q1.6

    // ---- n ≈ round(x / ln2) using 92/64 (Q2.6) ----
    // Sign-extend x once to 16b, then do shifts there (avoids WIDTHEXPAND)
    wire signed [15:0] x_se   = {{8{x[7]}}, x};
    wire signed [15:0] mul92  = (x_se <<< 7) - (x_se <<< 5) - (x_se <<< 2); // 128-32-4
    wire signed [15:0] nq2_6  = mul92 >>> 6;                                // still 16b

    // Round-to-nearest for signed Q2.6: add/sub 0.5 (=32) then >>>6
    wire signed [15:0] nq2_6_rnd = nq2_6 + (nq2_6[15] ? -16'sd32 : 16'sd32);
    wire signed [2:0]  n_round   = 3'(nq2_6_rnd >>> 6);       // clamp to [-3..+3] range

    // ---- r = x - n*ln2 in Q1.6; ln2 ≈ 44/64 = 32+8+4 ----
    // Sign-extend n_round to 10b before shifts (avoids WIDTHEXPAND)
    wire signed [9:0] n_se = {{7{n_round[2]}}, n_round};
    wire signed [9:0] nL   = (n_se <<< 5) + (n_se <<< 3) + (n_se <<< 2);  // n*44 in Q1.6 units
    wire signed [8:0] r    = $signed({x[7], x}) - $signed(nL[8:0]);      // Q1.6 (|r| small)

    // ---- e^r ≈ 1 + r  in Q1.6 ----
    // 1.0 in Q1.6 is 64
    wire signed [9:0] e_r  = 10'sd64 + $signed(r);  // Q1.6

    // ---- Apply 2^n via conditional shift; sign-extend to 16b before shift ----
    wire signed [15:0] e_r16       = {{6{e_r[9]}}, e_r};  // 10b -> 16b
    wire signed [15:0] e_scaled_pos =
        (n_round >= 0) ? (e_r16 <<< n_round) : (e_r16 >>> (-n_round));

    // Q1.6 -> UQ3.5 + clipping
    wire [8:0] e_sat = e_scaled_pos[15] ? 9'd0 :
                    (|e_scaled_pos[15:9] ? 9'h1FF : e_scaled_pos[8:0]);

    assign ex_result = e_sat;
endmodule
