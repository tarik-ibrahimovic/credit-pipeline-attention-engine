module ex (
    input wire [7:0] mac_result, // Q1.6
    output wire [7:0] ex_result   // Q1.6 
);
    wire signed [7:0] x = mac_result;
    wire signed [8:0] nq2_6 = $signed((x << 6) + (x << 4) + (x << 1)) >>> 6; // x*1/ln(2) = 92/64, x * 1.44 = 2.88, Q2.6 (-3,3)
    wire signed [1:0] n_round = nq2_6[5] ? (nq2_6[7:5] + 1) : (nq2_6[7:5]);  
    wire signed [8:0] nln2 = $signed((n_round << 5) + (n_round << 3) + (n_round << 2)) >>> 6; // n(2)*n = 3*ln(2) = 2.something, Q2.6
    wire signed [8:0] r = x - nln2; // Q0.7 =, should be between -0.35 and 0.35

    assign ex_result = 1<<n * (1+r+r*r/2);
endmodule