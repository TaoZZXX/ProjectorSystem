// 两个 160x90 RGB565 帧缓存。写入时钟来自摄像头 PCLK，读取时钟来自 HDMI
// 像素时钟。摄像头按 320x180 输出，横纵各抽 1/2 后写入；双缓存在 HDMI 帧
// 起点切换，画面不会撕裂。
//
// 注意：本模块的行同步实测为低电平有效（有效像素出现在 HREF 低电平期间），
// 与常见数据手册写法相反，故内部统一使用 cam_href_a = ~cam_href。
module camera_framebuffer (
    input  wire cam_pclk,
    input  wire cam_vsync,
    input  wire cam_href,
    input  wire [7:0] cam_data,
    input  wire cam_ready,
    input  wire pix_clk,
    input  wire video_frame_start,
    input  wire [7:0] read_x,
    input  wire [7:0] read_y,
    output wire [15:0] pixel_rgb565,
    output reg  frame_valid,
    output reg  [8:0] debug_lines,
    output reg  [8:0] debug_line_pixels,
    output reg  debug_captured,
    output reg  debug_published,
    output reg        cap_valid,
    output reg [15:0] cap_pix,
    output reg        cap_sof
);
    localparam integer PIXELS = 160 * 90;

    (* syn_ramstyle = "block_ram" *)
    reg [15:0] bank0 [0:PIXELS-1];
    (* syn_ramstyle = "block_ram" *)
    reg [15:0] bank1 [0:PIXELS-1];
    reg [15:0] q0, q1;
    reg bank_for_pixel;
    wire [13:0] read_addr = read_y * 14'd160 + read_x;

    reg displayed_bank;
    reg published_bank;
    reg published_toggle;
    reg acknowledged_toggle;
    reg [1:0] publish_sync;
    reg [1:0] bank_sync;
    reg [1:0] ack_sync;
    reg [1:0] ready_sync;

    reg vs_prev, href_prev;
    reg [8:0] line_y;
    reg [8:0] pixel_x;
    reg byte_phase;
    reg [7:0] first_byte;
    reg capture_active;
    reg write_bank;
    reg wr_en;
    reg wr_bank;
    reg [13:0] wr_addr;
    reg [15:0] wr_data;

    wire cam_href_a = ~cam_href;

    // 双时钟块 RAM：写入目标始终与显示目标不同。
    always @(posedge cam_pclk) begin
        if (wr_en && !wr_bank) bank0[wr_addr] <= wr_data;
        if (wr_en &&  wr_bank) bank1[wr_addr] <= wr_data;
    end
    always @(posedge pix_clk) begin
        q0 <= bank0[read_addr];
        q1 <= bank1[read_addr];
        bank_for_pixel <= displayed_bank;
    end
    assign pixel_rgb565 = bank_for_pixel ? q1 : q0;

    // 只在 HDMI 帧起点切换显示缓存，避免撕裂。
    always @(posedge pix_clk) begin
        publish_sync <= {publish_sync[0], published_toggle};
        bank_sync <= {bank_sync[0], published_bank};
        if (video_frame_start && publish_sync[1] != acknowledged_toggle) begin
            displayed_bank <= bank_sync[1];
            acknowledged_toggle <= publish_sync[1];
            frame_valid <= 1'b1;
        end
    end

    always @(posedge cam_pclk) begin
        ack_sync <= {ack_sync[0], acknowledged_toggle};
        ready_sync <= {ready_sync[0], cam_ready};
        vs_prev <= cam_vsync;
        href_prev <= cam_href_a;
        cap_sof <= (cam_vsync && !vs_prev);
        cap_valid <= 1'b0;
        wr_en <= 1'b0;
        if (cam_vsync) begin
            // 一帧结束后发布完整画面；上一帧还没显示完则丢弃本帧。
            if (!vs_prev) begin
                debug_lines <= line_y;
                debug_captured <= capture_active;
                debug_published <= capture_active && line_y >= 9'd180;
            end
            if (!vs_prev && capture_active && line_y >= 9'd180) begin
                published_bank <= write_bank;
                published_toggle <= ~published_toggle;
            end
            capture_active <= 1'b0;
            line_y <= 9'd0;
            pixel_x <= 9'd0;
            byte_phase <= 1'b0;
        end else begin
            if (vs_prev && ready_sync[1] &&
                ack_sync[1] == published_toggle) begin
                capture_active <= 1'b1;
                write_bank <= ~published_bank;
            end
            if (href_prev && !cam_href_a) begin
                debug_line_pixels <= pixel_x;
                line_y <= line_y + 1'b1;
                pixel_x <= 9'd0;
                byte_phase <= 1'b0;
            end else if (cam_href_a) begin
                byte_phase <= ~byte_phase;
                if (!byte_phase) first_byte <= cam_data;
                else begin
                    cap_pix <= {first_byte, cam_data};
                    cap_valid <= 1'b1;
                    pixel_x <= pixel_x + 1'b1;
                    // 320x180 输入：横纵各抽 1/2 得到 160x90，RGB565 高字节在前。
                    if (capture_active &&
                        !pixel_x[0] && !line_y[0] &&
                        line_y < 9'd180) begin
                        wr_en <= 1'b1;
                        wr_bank <= write_bank;
                        wr_addr <= (line_y[8:1]) * 14'd160 + pixel_x[8:1];
                        wr_data <= {first_byte, cam_data};
                    end
                end
            end else byte_phase <= 1'b0;
        end
    end

    initial begin
        displayed_bank = 1'b0;
        published_bank = 1'b0;
        published_toggle = 1'b0;
        acknowledged_toggle = 1'b0;
        publish_sync = 2'b00;
        bank_sync = 2'b00;
        ack_sync = 2'b00;
        ready_sync = 2'b00;
        vs_prev = 1'b0;
        href_prev = 1'b0;
        line_y = 9'd0;
        pixel_x = 9'd0;
        byte_phase = 1'b0;
        first_byte = 8'd0;
        capture_active = 1'b0;
        write_bank = 1'b1;
        wr_en = 1'b0;
        wr_bank = 1'b0;
        wr_addr = 14'd0;
        wr_data = 16'd0;
        bank_for_pixel = 1'b0;
        frame_valid = 1'b0;
        debug_lines = 9'd0;
        debug_line_pixels = 9'd0;
        debug_captured = 1'b0;
        debug_published = 1'b0;
        cap_valid = 1'b0;
        cap_pix = 16'd0;
        cap_sof = 1'b0;
    end
endmodule
