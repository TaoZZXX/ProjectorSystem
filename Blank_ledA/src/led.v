module led (
    input clock,
    output io_voltage
);
    
parameter count_value = 13_999_999;

reg [23:0] count_value_reg = 0;
reg count_value_flag = 0;

always @(posedge clock) begin
    if (count_value_reg <= count_value) begin
        count_value_reg <= count_value_reg + 1'b1;
        count_value_flag <= 1'b0;
    end
    else begin
        count_value_reg <= 0;
        count_value_flag <= 1'b1;
    end
end

reg io_voltage_reg = 1'b1;

always @(posedge clock) begin
    if (count_value_flag) begin
        io_voltage_reg <= ~ io_voltage_reg;
    end
end

assign io_voltage = io_voltage_reg;

endmodule