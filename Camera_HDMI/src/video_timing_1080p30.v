// 1920x1080 @ 30 Hz（CEA-861 简化时序，像素时钟 74.25 MHz）。
// 与 720p60 共用同一个 74.25 MHz 像素时钟，PLL 不需要改动。
module video_timing_1080p30 (
    input  wire pix_clk,
    input  wire rst_n,
    output reg [11:0] x,
    output reg [11:0] y,
    output wire de,
    output reg hsync,
    output reg vsync
);
    // 行：1920 有效 + 88 前肩 + 44 同步 + 148 后肩 = 2200
    // 场：1080 有效 + 4 前肩 + 5 同步 + 36 后肩 = 1125
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 12'd0;
            y <= 12'd0;
        end else if (x == 12'd2199) begin
            x <= 12'd0;
            if (y == 12'd1124) y <= 12'd0;
            else y <= y + 1'b1;
        end else begin
            x <= x + 1'b1;
        end
    end

    // 行同步：x = 1920+88 .. 1920+88+43 为高
    always @(*) begin
        hsync = (x >= 12'd2008) && (x < 12'd2052);
    end

    // 场同步：y = 1080+4 .. 1080+8 为高
    always @(*) begin
        vsync = (y >= 12'd1084) && (y < 12'd1089);
    end

    assign de = (x < 12'd1920) && (y < 12'd1080);
endmodule
