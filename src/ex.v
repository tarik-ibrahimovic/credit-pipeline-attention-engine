module ex (
    input wire [16:0] mac_result, // Q3.13
    output wire [7:0] ex_result   // Q1.6 
);
    assign ex_result = mac_result[7:0];
endmodule