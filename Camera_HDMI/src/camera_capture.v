// 将摄像头的两个 8 位字节拼成 RGB565 像素。当前模块实测 HREF 低有效。
// 不再丢弃隔行、隔列的像素，320x180 全部交给 SDRAM。
module camera_capture (
    input wire cam_pclk, cam_vsync, cam_href,
    input wire [7:0] cam_data,
    input wire ready,
    output reg pixel_valid = 1'b0,
    output reg [15:0] pixel = 16'd0,
    output reg frame_start = 1'b0,
    output reg [8:0] debug_lines = 9'd0,
    output reg [8:0] debug_pixels = 9'd0
);
    reg vs_prev = 1'b0, href_prev = 1'b0;
    reg [1:0] ready_sync = 2'd0;
    reg [9:0] column = 10'd0, row = 10'd0;
    reg phase = 1'b0;
    reg [7:0] high_byte = 8'd0;
    wire href_active = ~cam_href;
    always @(posedge cam_pclk) begin
        ready_sync <= {ready_sync[0], ready};
        vs_prev <= cam_vsync;
        href_prev <= href_active;
        frame_start <= cam_vsync && !vs_prev;
        pixel_valid <= 1'b0;
        if (cam_vsync) begin
            if (!vs_prev) debug_lines <= row[8:0];
            column <= 10'd0;
            row <= 10'd0;
            phase <= 1'b0;
        end else if (href_prev && !href_active) begin
            debug_pixels <= column[8:0];
            column <= 10'd0;
            if (row != 10'h3ff) row <= row + 1'b1;
            phase <= 1'b0;
        end else if (href_active) begin
            phase <= ~phase;
            if (!phase) high_byte <= cam_data;
            else begin
                if (column != 10'h3ff) column <= column + 1'b1;
                pixel <= {high_byte, cam_data};
                pixel_valid <= ready_sync[1] && column < 10'd320 && row < 10'd180;
            end
        end else phase <= 1'b0;
    end
endmodule
