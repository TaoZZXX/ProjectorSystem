// Tang Nano 20K + OV5640：摄像头并口 -> 160x90 RGB565 双缓存 -> 720p60 HDMI。
// 画面居中放大 6 倍显示为 960x540，四周留黑。
//
// 实测要点：本模块的 HREF 为低电平有效，有效像素出现在 HREF 低电平期间；
// 传感器按 320x180 输出，FPGA 横纵各抽 1/2 写入帧缓存。
module camera_hdmi_top (
    input  wire clk,
    input  wire cam_pclk,
    input  wire cam_vsync,
    input  wire cam_href,
    input  wire [7:0] cam_data,
    inout  wire cam_sda,
    output wire cam_scl,
    output wire cam_rst_n,
    output wire cam_pwdn,
    output wire uart_tx,
    output wire dvi_txc_p, dvi_txc_n,
    output wire dvi_tx0_p, dvi_tx0_n,
    output wire dvi_tx1_p, dvi_tx1_n,
    output wire dvi_tx2_p, dvi_tx2_n,
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    wire serial_clk, pix_clk, pll_lock;
    TMDS_rPLL u_pll (
        .clkin(clk), .clkout(serial_clk), .lock(pll_lock)
    );
    CLKDIV u_clkdiv (
        .HCLKIN(serial_clk), .RESETN(pll_lock),
        .CALIB(1'b1), .CLKOUT(pix_clk)
    );
    defparam u_clkdiv.DIV_MODE = "5";
    defparam u_clkdiv.GSREN = "false";

    // ---- 摄像头配置 ----
    wire init_ready, init_error;
    wire [15:0] sensor_id;
    wire [7:0] sensor_ctrl;
    wire [7:0] sensor_pad;
    ov5640_init u_camera_init (
        .clk_27m(clk), .reset_n(pll_lock),
        .cam_sda(cam_sda), .cam_scl(cam_scl),
        .cam_rst_n(cam_rst_n), .cam_pwdn(cam_pwdn),
        .ready(init_ready), .error(init_error),
        .sensor_id(sensor_id), .sensor_ctrl(sensor_ctrl),
        .sensor_pad(sensor_pad)
    );

    // ---- HDMI 720p60 时序 ----
    wire [11:0] x, y;
    wire de, hs, vs;
    video_timing_720p60 u_video_timing (
        .pix_clk(pix_clk), .rst_n(pll_lock),
        .x(x), .y(y), .de(de), .hsync(hs), .vsync(vs)
    );

    // ---- 画面居中：160x90 缓存放大 6 倍占 960x540，其余留黑 ----
    localparam [11:0] WIN_X0 = 12'd160;
    localparam [11:0] WIN_Y0 = 12'd90;
    localparam [11:0] WIN_W  = 12'd960;
    localparam [11:0] WIN_H  = 12'd540;
    wire in_win = (x >= WIN_X0) && (x < WIN_X0 + WIN_W) &&
                  (y >= WIN_Y0) && (y < WIN_Y0 + WIN_H);
    reg [7:0] src_x, src_y;
    reg [2:0] rep_x, rep_y;
    always @(posedge pix_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            src_x <= 8'd0; src_y <= 8'd0;
            rep_x <= 3'd0; rep_y <= 3'd0;
        end else if (in_win) begin
            if (x == WIN_X0) begin
                src_x <= 8'd0;
                rep_x <= 3'd0;
                if (y == WIN_Y0) begin
                    src_y <= 8'd0;
                    rep_y <= 3'd0;
                end else if (rep_y == 3'd5) begin
                    rep_y <= 3'd0;
                    src_y <= src_y + 1'b1;
                end else rep_y <= rep_y + 1'b1;
            end else if (rep_x == 3'd5) begin
                rep_x <= 3'd0;
                src_x <= src_x + 1'b1;
            end else rep_x <= rep_x + 1'b1;
        end
    end
    wire [7:0] read_x = (in_win && src_x < 8'd160) ? src_x : 8'd0;
    wire [7:0] read_y = (in_win && src_y < 8'd90) ? src_y : 8'd0;
    reg in_win_q;
    always @(posedge pix_clk or negedge pll_lock) begin
        if (!pll_lock) in_win_q <= 1'b0;
        else in_win_q <= in_win;
    end

    // ---- 帧缓存 ----
    wire [15:0] pixel_rgb565;
    wire        cap_valid, cap_sof;
    wire [15:0] cap_pix;
    wire frame_valid;
    wire [8:0] debug_lines;
    wire [8:0] debug_line_pixels;
    wire debug_captured, debug_published;
    camera_framebuffer u_framebuffer (
        .cam_pclk(cam_pclk), .cam_vsync(cam_vsync), .cam_href(cam_href),
        .cam_data(cam_data), .cam_ready(init_ready),
        .pix_clk(pix_clk), .video_frame_start(x == 12'd0 && y == 12'd0),
        .read_x(read_x), .read_y(read_y),
        .pixel_rgb565(pixel_rgb565), .frame_valid(frame_valid),
        .debug_lines(debug_lines), .debug_line_pixels(debug_line_pixels),
        .debug_captured(debug_captured), .debug_published(debug_published),
        .cap_valid(cap_valid), .cap_pix(cap_pix), .cap_sof(cap_sof)
    );

    // ---- 状态上报：115200 8N1，每两秒一行 ----
    reg [25:0] report_count;
    reg [2:0] pclk_sync, vs_sync, href_sync;
    reg pclk_seen, vs_seen, href_seen;
    reg [1:0] frame_sync;
    reg [15:0] sample_left, sample_middle, sample_right;
    always @(posedge clk or negedge pll_lock) begin
        if (!pll_lock) begin
            report_count <= 26'd0;
            pclk_sync <= 3'b0; vs_sync <= 3'b0; href_sync <= 3'b0;
            pclk_seen <= 1'b0; vs_seen <= 1'b0; href_seen <= 1'b0;
            frame_sync <= 2'b0;
        end else begin
            if (report_count == 26'd53999999) report_count <= 26'd0;
            else report_count <= report_count + 1'b1;
            pclk_sync <= {pclk_sync[1:0], cam_pclk};
            vs_sync <= {vs_sync[1:0], cam_vsync};
            href_sync <= {href_sync[1:0], cam_href};
            frame_sync <= {frame_sync[0], frame_valid};
            if (pclk_sync[2] != pclk_sync[1]) pclk_seen <= 1'b1;
            if (vs_sync[2:1] == 2'b01) vs_seen <= 1'b1;
            if (href_sync[2:1] == 2'b01) href_seen <= 1'b1;
        end
    end

    // 取三个位置的同色度采样，便于串口判断画面是否随位置变化。
    always @(posedge pix_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            sample_left <= 16'd0;
            sample_middle <= 16'd0;
            sample_right <= 16'd0;
        end else begin
            if (y == WIN_Y0 + 12'd270 && x == WIN_X0 + 12'd80)
                sample_left <= pixel_rgb565;
            if (y == WIN_Y0 + 12'd270 && x == WIN_X0 + 12'd480)
                sample_middle <= pixel_rgb565;
            if (y == WIN_Y0 + 12'd270 && x == WIN_X0 + 12'd880)
                sample_right <= pixel_rgb565;
        end
    end

    uart_hex_report #(.CLK_HZ(27_000_000)) u_report (
        .clk(clk), .rst_n(pll_lock),
        .report_valid(report_count == 26'd53999999),
        .report_pass(frame_sync[1]),
        .fail_code(sample_right[15:8]),
        .jedec_id({8'hca, cam_sda, cam_scl, cam_vsync,
                   cam_href, cam_rst_n, cam_pwdn, 2'b00,
                   init_ready, init_error,
                   pclk_seen, vs_seen, href_seen, frame_sync[1],
                   debug_captured, debug_published}),
        .readback_data(sd_dbg),
        .expected_data({sensor_ctrl, sensor_pad,
                        sample_right[15:8], debug_lines[7:0]}),
        .uart_tx(uart_tx)
    );

    // ---- 像素输出：块 RAM 同步读延迟一个像素，DE/HS/VS 也延迟一个像素 ----
    reg de_q, hs_q, vs_q;
    reg [1:0] init_sync, error_sync;
    always @(posedge pix_clk or negedge pll_lock) begin
        if (!pll_lock) begin
            de_q <= 1'b0; hs_q <= 1'b0; vs_q <= 1'b0;
            init_sync <= 2'b00; error_sync <= 2'b00;
        end else begin
            de_q <= de; hs_q <= hs; vs_q <= vs;
            init_sync <= {init_sync[0], init_ready};
            error_sync <= {error_sync[0], init_error};
        end
    end

    // 状态色：红=初始化中，紫=SCCB 失败，蓝=等待首帧；收到帧后显示图像。
    wire [7:0] red = frame_valid ?
        (in_win_q ? {pixel_rgb565[15:11], pixel_rgb565[15:13]} : 8'h00) :
        (init_sync[1] ? (error_sync[1] ? 8'hff : 8'h00) : 8'hff);
    wire [7:0] green = frame_valid ?
        (in_win_q ? {pixel_rgb565[10:5], pixel_rgb565[10:9]} : 8'h00) : 8'h00;
    wire [7:0] blue = frame_valid ?
        (in_win_q ? {pixel_rgb565[4:0], pixel_rgb565[4:2]} : 8'h00) :
        (init_sync[1] ? 8'hff : 8'h00);

    wire [2:0] tmds_p, tmds_n;
    DVI_TX_Top u_dvi (
        .I_rst_n(pll_lock),
        .I_serial_clk(serial_clk), .I_rgb_clk(pix_clk),
        .I_rgb_vs(vs_q), .I_rgb_hs(hs_q), .I_rgb_de(de_q),
        .I_rgb_r(red), .I_rgb_g(green), .I_rgb_b(blue),
        .O_tmds_clk_p(dvi_txc_p), .O_tmds_clk_n(dvi_txc_n),
        .O_tmds_data_p(tmds_p), .O_tmds_data_n(tmds_n)
    );
    assign {dvi_tx2_p, dvi_tx1_p, dvi_tx0_p} = tmds_p;
    assign {dvi_tx2_n, dvi_tx1_n, dvi_tx0_n} = tmds_n;

    wire [15:0] sd_pix;
    wire        sd_ok;
    wire [31:0] sd_dbg;
    sdram_fb u_sdram_fb (
        .clk(clk), .pll_lock_27(pll_lock),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm), .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq),
        .cam_pclk(cam_pclk), .cam_valid(cap_valid),
        .cam_pix(cap_pix), .cam_sof(cap_sof),
        .pix_clk(pix_clk), .x(x), .y(y),
        .pix_out(sd_pix), .frame_ok(sd_ok), .dbg(sd_dbg)
    );
endmodule
