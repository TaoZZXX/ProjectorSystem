module tmds_encoder (
    input clk,
    input de,
    input [7:0] din,
    input [1:0] ctl,
    output reg [9:0] dout
);

reg [8:0] q_m;
reg [3:0] ones;

always @(*) begin
    ones = din[0] + din[1] + din[2] + din[3] + din[4] + din[5] + din[6] + din[7];

    if (ones > 4 || (ones == 4 && din[0] == 1'b0)) begin
        q_m[8:0] = {1'b0, din[0] ^ din[1], din[1] ^ din[2], din[2] ^ din[3], din[3] ^ din[4], 
                din[4] ^ din[5] ,din[5] ^ din[6], din[6] ^ din[7], din[7]};
    end else begin
        q_m[8:0] = {1'b1, ~(din[0]^din[1]), ~(din[1]^din[2]), ~(din[2]^din[3]), ~(din[3]^din[4]),
                ~(din[4]^din[5]), ~(din[5]^din[6]), ~(din[6]^din[7]), ~din[7]};
    end
end
    
always @(posedge clk) begin
    if (!de) begin
        case (ctl)
            2'b00: dout <= 10'b1101010100;
            2'b01: dout <= 10'b0010101011;
            2'b10: dout <= 10'b0101010100;
            2'b11: dout <= 10'b1010101011;
        endcase
    end else begin
        dout <= {~q_m[8], q_m};
    end

end

endmodule