// OV5640 VGA 输入裁成 640x360 RGB565，经 SDRAM 双帧缓存后送到 720p60 HDMI。
// 画面按 2 倍整数放大，铺满 1280x720 有效显示区。
module camera_hdmi_top (
    input wire clk, cam_pclk, cam_vsync, cam_href,
    input wire [7:0] cam_data,
    inout wire cam_sda,
    output wire cam_scl, cam_rst_n, cam_pwdn, uart_tx,
    output wire dvi_txc_p, dvi_txc_n, dvi_tx0_p, dvi_tx0_n,
    output wire dvi_tx1_p, dvi_tx1_n, dvi_tx2_p, dvi_tx2_n,
    output wire O_sdram_clk, O_sdram_cke, O_sdram_cs_n,
    output wire O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n,
    output wire [3:0] O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0] O_sdram_ba,
    inout wire [31:0] IO_sdram_dq
);
    wire serial_clk, pix_clk, pll_lock;
    TMDS_rPLL u_pll (.clkin(clk), .clkout(serial_clk), .lock(pll_lock));
    CLKDIV u_clkdiv (.HCLKIN(serial_clk), .RESETN(pll_lock),
        .CALIB(1'b1), .CLKOUT(pix_clk));
    defparam u_clkdiv.DIV_MODE = "5";
    defparam u_clkdiv.GSREN = "false";

    wire init_ready, init_error;
    wire [15:0] sensor_id;
    wire [7:0] sensor_ctrl, sensor_pad;
    ov5640_init u_camera_init (
        .clk_27m(clk), .reset_n(pll_lock), .cam_sda(cam_sda), .cam_scl(cam_scl),
        .cam_rst_n(cam_rst_n), .cam_pwdn(cam_pwdn), .ready(init_ready),
        .error(init_error), .sensor_id(sensor_id), .sensor_ctrl(sensor_ctrl),
        .sensor_pad(sensor_pad)
    );
    wire [11:0] x, y;
    wire de, hs, vs;
    video_timing_720p60 u_video_timing (.pix_clk(pix_clk), .rst_n(pll_lock),
        .x(x), .y(y), .de(de), .hsync(hs), .vsync(vs));

    wire in_win = x < 12'd1280 && y < 12'd720;
    reg [9:0] src_x;
    reg [8:0] src_y;
    reg repeat_x, repeat_y;
    always @(posedge pix_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            src_x <= 10'd0; src_y <= 9'd0; repeat_x <= 1'b0; repeat_y <= 1'b0;
        end else if (in_win) begin
            if (x == 12'd0) begin
                src_x <= 10'd0; repeat_x <= 1'b0;
                if (y == 12'd0) begin src_y <= 9'd0; repeat_y <= 1'b0; end
                else if (repeat_y) begin
                    src_y <= src_y + 1'b1; repeat_y <= 1'b0;
                end else repeat_y <= 1'b1;
            end else if (repeat_x) begin
                repeat_x <= 1'b0; src_x <= src_x + 1'b1;
            end else repeat_x <= repeat_x + 1'b1;
        end
    end
    // 在 RAM 采样的同一拍给出当前显示坐标，补偿计数器的非阻塞赋值延迟。
    wire [9:0] read_x = !in_win || x == 12'd0 ? 10'd0 :
                       repeat_x ? src_x + 1'b1 : src_x;
    wire [8:0] read_y = !in_win || y == 12'd0 ? 9'd0 :
                       x == 12'd0 && repeat_y ? src_y + 1'b1 : src_y;
    // 第一行在场消隐期预取；之后每两条显示行预取一条新的源行。
    wire first_request = y == 12'd721 && x == 12'd0;
    wire following_request = in_win && x == 12'd1 && !repeat_y && src_y < 9'd359;
    wire [8:0] requested_line = first_request ? 9'd0 : src_y + 1'b1;

    wire cap_valid, cap_sof;
    wire [15:0] cap_pixel;
    wire [9:0] debug_lines, debug_pixels;
    camera_capture u_capture (
        .cam_pclk(cam_pclk), .cam_vsync(cam_vsync), .cam_href(cam_href),
        .cam_data(cam_data), .ready(init_ready), .pixel_valid(cap_valid),
        .pixel(cap_pixel), .frame_start(cap_sof),
        .debug_lines(debug_lines), .debug_pixels(debug_pixels)
    );
    wire [15:0] pixel_rgb565;
    wire frame_valid;
    wire [31:0] memory_debug;
    sdram_framebuffer u_memory (
        .clk(clk), .reset_n(pll_lock), .cam_pclk(cam_pclk),
        .cam_valid(cap_valid), .cam_sof(cap_sof), .cam_pixel(cap_pixel),
        .pix_clk(pix_clk), .x(x), .y(y), .source_x(read_x), .source_y(read_y),
        .window_active(in_win), .next_line_request(first_request || following_request),
        .next_line(requested_line), .pixel_out(pixel_rgb565),
        .frame_valid(frame_valid), .debug(memory_debug),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm), .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq)
    );

    reg de_q, hs_q, vs_q;
    reg [1:0] ready_sync, error_sync;
    always @(posedge pix_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            de_q <= 1'b0; hs_q <= 1'b0; vs_q <= 1'b0;
            ready_sync <= 2'd0; error_sync <= 2'd0;
        end else begin
            de_q <= de; hs_q <= hs; vs_q <= vs;
            ready_sync <= {ready_sync[0], init_ready};
            error_sync <= {error_sync[0], init_error};
        end
    end
    wire [7:0] red = frame_valid ? {pixel_rgb565[15:11], pixel_rgb565[15:13]} :
        (!ready_sync[1] || error_sync[1] ? 8'hff : 8'h00);
    wire [7:0] green = frame_valid ? {pixel_rgb565[10:5], pixel_rgb565[10:9]} : 8'd0;
    wire [7:0] blue = frame_valid ? {pixel_rgb565[4:0], pixel_rgb565[4:2]} :
        (ready_sync[1] ? 8'hff : 8'h00);
    wire [2:0] tmds_p, tmds_n;
    DVI_TX_Top u_dvi (
        .I_rst_n(pll_lock), .I_serial_clk(serial_clk), .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs_q), .I_rgb_hs(hs_q), .I_rgb_de(de_q),
        .I_rgb_r(red), .I_rgb_g(green), .I_rgb_b(blue),
        .O_tmds_clk_p(dvi_txc_p), .O_tmds_clk_n(dvi_txc_n),
        .O_tmds_data_p(tmds_p), .O_tmds_data_n(tmds_n)
    );
    assign {dvi_tx2_p, dvi_tx1_p, dvi_tx0_p} = tmds_p;
    assign {dvi_tx2_n, dvi_tx1_n, dvi_tx0_n} = tmds_n;

    // 串口：RB 高 16 位是保存帧数，低 16 位是读取行数，均应持续增加。
    reg [25:0] report_count;
    reg [1:0] frame_sync;
    always @(posedge clk or negedge pll_lock) begin
        if (!pll_lock) begin report_count <= 26'd0; frame_sync <= 2'd0; end
        else begin
            report_count <= report_count == 26'd53999999 ? 26'd0 : report_count + 1'b1;
            frame_sync <= {frame_sync[0], frame_valid};
        end
    end
    uart_hex_report #(.CLK_HZ(27_000_000)) u_report (
        .clk(clk), .rst_n(pll_lock), .report_valid(report_count == 26'd53999999),
        .report_pass(frame_sync[1]), .fail_code({6'd0, init_error, frame_sync[1]}),
        .jedec_id({sensor_id, 6'd0, init_ready, init_error}),
        .readback_data(memory_debug),
        .expected_data({6'd0, debug_lines, 6'd0, debug_pixels}), .uart_tx(uart_tx)
    );
endmodule
