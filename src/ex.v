module ex (
    input  wire [7:0] mac_result,  // Q1.6
    output wire [7:0] ex_result    // Q1.6
);
    // Alias
    wire signed [7:0] x = mac_result;  // Q1.6

    // n ≈ round(x / ln2) using 92/64 = 1/ln2  (Q2.6 intermediate)
    // 92 = 128 - 32 - 4  → 3 shifts, 2 subs
    wire signed [8:0] nq2_6 = ($signed(x) <<< 7) - ($signed(x) <<< 5) - ($signed(x) <<< 2); // Q2.6 *before* /64
    // divide by 64 with signed round-to-nearest (±0.5 = 32)
    wire signed [8:0] nq2_6_div = nq2_6 + (nq2_6[8] ? -9'sd32 : 9'sd32);
    wire signed [2:0] n_round   = nq2_6_div >>> 6;  // integer n in [-3..+3]

    // r = x - n*ln2, all in Q1.6.  ln2 ≈ 44/64, and 44 = 32+8+4
    wire signed [9:0] nL   = ($signed(n_round) <<< 5) + ($signed(n_round) <<< 3) + ($signed(n_round) <<< 2); // n*44 in Q1.6 units
    wire signed [8:0] r    = $signed(x) - $signed(nL[8:0]);   // Q1.6 (|r| ≲ 0.35)

    // e^r ≈ 1 + r + r^2/2  in Q1.6
    // r^2: (Q1.6)^2 = Q2.12  → to Q1.6: >>6, then /2: >>1  → total >>7
    wire signed [17:0] r2      = $signed(r) * $signed(r);   // Q2.12
    wire signed [8:0]  r2_half = $signed(r2 >>> 7);         // Q1.6
    wire signed [9:0]  e_r     = 10'sd64 + $signed(r) + $signed(r2_half); // 64 = 1.0 in Q1.6

    // Apply 2^n by conditional shift, then saturate to Q1.6 (unsigned output, clamp <0 to 0)
    wire signed [15:0] e_scaled_pos = (n_round >= 0) ? ($signed(e_r) <<< n_round) : ($signed(e_r) >>> (-n_round));

    // Saturate to [0, 127] (0 .. 1.984 in Q1.6)
    wire [7:0] e_sat =
        (e_scaled_pos[15] == 1'b1) ? 8'd0 :               // negative → 0
        (|e_scaled_pos[15:7] ? 8'd127 : e_scaled_pos[7:0]); // overflow → 127, else low byte

    assign ex_result = e_sat;
endmodule
