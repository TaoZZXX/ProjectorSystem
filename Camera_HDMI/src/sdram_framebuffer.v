// 640x360 RGB565 双帧 SDRAM 缓存，保留有效区域的全部像素及 16 位颜色。
// 摄像头 -> 异步 FIFO -> SDRAM 写入；SDRAM -> 双行缓存 -> HDMI。
// 每个 SDRAM 32 位字放两个相邻像素，低 16 位为左像素。
module sdram_framebuffer (
    input wire clk, reset_n,
    input wire cam_pclk, cam_valid, cam_sof,
    input wire [15:0] cam_pixel,
    input wire pix_clk,
    input wire [11:0] x, y,
    input wire [9:0] source_x,
    input wire [8:0] source_y,
    input wire window_active,
    input wire next_line_request,
    input wire [8:0] next_line,
    output wire [15:0] pixel_out,
    output reg frame_valid = 1'b0,
    output wire [31:0] debug,
    output wire O_sdram_clk, O_sdram_cke, O_sdram_cs_n,
    output wire O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n,
    output wire [3:0] O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0] O_sdram_ba,
    inout wire [31:0] IO_sdram_dq
);
    localparam [16:0] FRAME_WORDS = 17'd115200;
    // 每帧占 115200 个 32 位字；双帧按 131072 字对齐，互不重叠。
    wire mem_clk, chip_clk, mem_lock;
    rPLL_108MHz u_mem_pll (.clkin(clk), .clkout(mem_clk),
        .clkoutp(chip_clk), .lock(mem_lock));
    wire mem_reset_n = reset_n && mem_lock;
    reg [7:0] reset_delay = 8'd0;
    reg mem_run = 1'b0;
    always @(posedge mem_clk or negedge mem_reset_n) begin
        if (!mem_reset_n) begin reset_delay <= 8'd0; mem_run <= 1'b0; end
        else if (!mem_run) begin
            reset_delay <= reset_delay + 1'b1;
            if (&reset_delay) mem_run <= 1'b1;
        end
    end
    reg cmd_en;
    reg [2:0] cmd;
    reg [20:0] addr;
    reg [31:0] write_data;
    wire [31:0] read_data;
    wire ack, init_done;
    SDRAM_Controller_HS_Top u_controller (
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm), .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq),
        .I_sdrc_rst_n(mem_run), .I_sdrc_clk(mem_clk), .I_sdram_clk(chip_clk),
        .I_sdrc_cmd_en(cmd_en), .I_sdrc_cmd(cmd),
        .I_sdrc_precharge_ctrl(1'b1), .I_sdram_power_down(1'b0),
        .I_sdram_selfrefresh(1'b0), .I_sdrc_addr(addr),
        .I_sdrc_dqm(4'd0), .I_sdrc_data(write_data), .I_sdrc_data_len(8'd0),
        .O_sdrc_data(read_data), .O_sdrc_init_done(init_done), .O_sdrc_cmd_ack(ack)
    );

    // 512x49 FIFO：17 位帧内字地址 + 32 位像素。
    // 指针额外带一位回卷位；满时丢弃当前整帧剩余数据，绝不拼接两帧。
    (* syn_ramstyle = "block_ram" *) reg [48:0] fifo_mem [0:511];
    reg [9:0] wp = 10'd0, wg = 10'd0, rp, rg;
    reg [9:0] rg1 = 10'd0, rg2 = 10'd0, wg1, wg2;
    wire [9:0] wp_next = wp + 1'b1;
    wire [9:0] wg_next = (wp_next >> 1) ^ wp_next;
    wire [9:0] rp_next = rp + 1'b1;
    wire fifo_full = wg_next == {~rg2[9:8], rg2[7:0]};
    wire fifo_empty = rg == wg2;
    reg half = 1'b0, drop_frame = 1'b1;
    reg [15:0] first_pixel = 16'd0;
    reg [16:0] camera_word = 17'd0;
    reg [15:0] dropped_frames = 16'd0;
    always @(posedge cam_pclk or negedge reset_n) begin
        if (!reset_n) begin
            wp <= 10'd0; wg <= 10'd0; rg1 <= 10'd0; rg2 <= 10'd0;
            half <= 1'b0; drop_frame <= 1'b1; camera_word <= 17'd0;
            first_pixel <= 16'd0; dropped_frames <= 16'd0;
        end else begin
            rg1 <= rg; rg2 <= rg1;
            if (cam_sof) begin
                half <= 1'b0; camera_word <= 17'd0; drop_frame <= 1'b0;
            end else if (cam_valid && !drop_frame) begin
                if (!half) begin first_pixel <= cam_pixel; half <= 1'b1; end
                else begin
                    half <= 1'b0;
                    if (fifo_full) begin
                        drop_frame <= 1'b1;
                        dropped_frames <= dropped_frames + 1'b1;
                    end else begin
                        fifo_mem[wp[8:0]] <= {camera_word, cam_pixel, first_pixel};
                        wp <= wp_next; wg <= wg_next;
                        camera_word <= camera_word + 1'b1;
                        if (camera_word == FRAME_WORDS - 1'b1) drop_frame <= 1'b1;
                    end
                end
            end
        end
    end
    reg [48:0] fifo_q;
    always @(posedge mem_clk) fifo_q <= fifo_mem[rp[8:0]];

    // 帧发布握手：显示侧只在场消隐切页，写侧在收到确认前不复用旧页。
    reg published_page, publish_toggle;
    reg displayed_page = 1'b0, display_ack = 1'b0;
    reg [1:0] publish_sync = 2'd0, page_sync = 2'd0;
    reg [1:0] ack_sync, display_page_sync;
    always @(posedge pix_clk or negedge reset_n) begin
        if (!reset_n) begin
            publish_sync <= 2'd0; page_sync <= 2'd0;
            displayed_page <= 1'b0; display_ack <= 1'b0; frame_valid <= 1'b0;
        end else begin
            publish_sync <= {publish_sync[0], publish_toggle};
            page_sync <= {page_sync[0], published_page};
            if (x == 12'd0 && y == 12'd720 && publish_sync[1] != display_ack) begin
                displayed_page <= page_sync[1];
                display_ack <= publish_sync[1];
                frame_valid <= 1'b1;
            end
        end
    end

    // 行请求通过翻转位跨域，行号在下一次请求前保持不变。
    reg request_toggle = 1'b0;
    reg [8:0] request_line = 9'd0;
    reg [1:0] request_sync;
    reg request_done;
    always @(posedge pix_clk or negedge reset_n) begin
        if (!reset_n) begin request_toggle <= 1'b0; request_line <= 8'd0; end
        else if (next_line_request && frame_valid) begin
            request_line <= next_line;
            request_toggle <= ~request_toggle;
        end
    end

    // 两条 640 像素行缓存；每个 SDRAM 字保存两个相邻 RGB565 像素。
    (* syn_ramstyle = "block_ram" *) reg [31:0] line0 [0:319];
    (* syn_ramstyle = "block_ram" *) reg [31:0] line1 [0:319];
    reg [31:0] line0_q, line1_q;
    reg parity_q, half_q, active_q;
    wire [8:0] line_read_addr = window_active ? source_x[9:1] : 9'd0;
    always @(posedge pix_clk) begin
        line0_q <= line0[line_read_addr]; line1_q <= line1[line_read_addr];
        parity_q <= source_y[0]; half_q <= source_x[0]; active_q <= window_active;
    end
    wire [31:0] line_q = parity_q ? line1_q : line0_q;
    assign pixel_out = !active_q ? 16'd0 : (half_q ? line_q[31:16] : line_q[15:0]);

    localparam [3:0] IDLE = 4'd0, FETCH = 4'd1, CHECK = 4'd2,
        ACT = 4'd3, ACT_ACK = 4'd4, COMMAND = 4'd5, COMMAND_ACK = 4'd6,
        READ_CAPTURE = 4'd7, GAP = 4'd8;
    reg [3:0] state;
    reg reading, accepting_frame, write_page;
    reg [16:0] expected_word;
    reg [8:0] fetch_line, fetch_word;
    reg fetch_page, fetch_token;
    reg [15:0] completed_frames, completed_lines;
    always @(posedge mem_clk or negedge mem_run) begin
        if (!mem_run) begin
            state <= IDLE; cmd_en <= 1'b0; cmd <= 3'd0; addr <= 21'd0;
            write_data <= 32'd0; rp <= 10'd0; rg <= 10'd0; wg1 <= 10'd0; wg2 <= 10'd0;
            ack_sync <= 2'd0; display_page_sync <= 2'd0; request_sync <= 2'd0;
            published_page <= 1'b0; publish_toggle <= 1'b0; request_done <= 1'b0;
            reading <= 1'b0; accepting_frame <= 1'b0; write_page <= 1'b1;
            expected_word <= 17'd0; fetch_line <= 9'd0; fetch_word <= 9'd0;
            fetch_page <= 1'b0; fetch_token <= 1'b0;
            completed_frames <= 16'd0; completed_lines <= 16'd0;
        end else begin
            cmd_en <= 1'b0;
            wg1 <= wg; wg2 <= wg1;
            ack_sync <= {ack_sync[0], display_ack};
            display_page_sync <= {display_page_sync[0], displayed_page};
            request_sync <= {request_sync[0], request_toggle};
            case (state)
                IDLE: if (init_done) begin
                    // 行读取优先，保证 HDMI 连续输出。FIFO 吸收摄像头的暂时积压。
                    if (request_sync[1] != request_done) begin
                        reading <= 1'b1; fetch_line <= request_line;
                        fetch_word <= 9'd0; fetch_page <= display_page_sync[1];
                        fetch_token <= request_sync[1]; state <= ACT;
                    end else if (!fifo_empty) state <= FETCH;
                end
                FETCH: state <= CHECK;
                CHECK: begin
                    if (fifo_q[48:32] == 17'd0) begin
                        if (ack_sync[1] == publish_toggle) begin
                            write_page <= ~published_page;
                            accepting_frame <= 1'b1; expected_word <= 17'd0;
                            reading <= 1'b0; write_data <= fifo_q[31:0]; state <= ACT;
                        end else begin
                            accepting_frame <= 1'b0; rp <= rp_next;
                            rg <= (rp_next >> 1) ^ rp_next; state <= IDLE;
                        end
                    end else if (accepting_frame && fifo_q[48:32] == expected_word) begin
                        reading <= 1'b0; write_data <= fifo_q[31:0]; state <= ACT;
                    end else begin
                        accepting_frame <= 1'b0; rp <= rp_next;
                        rg <= (rp_next >> 1) ^ rp_next; state <= IDLE;
                    end
                end
                ACT: begin
                    // 地址单位为 32 位字；bit17 选择帧页，低位为帧内字偏移。
                    addr <= reading ? {3'd0, fetch_page, 17'd0} +
                        {12'd0, fetch_line} * 21'd320 + {12'd0, fetch_word} :
                        {3'd0, write_page, 17'd0} + {4'd0, expected_word};
                    cmd <= 3'b011; cmd_en <= 1'b1; state <= ACT_ACK;
                end
                ACT_ACK: if (ack) state <= COMMAND;
                COMMAND: begin
                    cmd <= reading ? 3'b101 : 3'b100;
                    cmd_en <= 1'b1; state <= COMMAND_ACK;
                end
                COMMAND_ACK: if (ack) begin
                    if (reading) state <= READ_CAPTURE;
                    else begin
                        rp <= rp_next; rg <= (rp_next >> 1) ^ rp_next;
                        expected_word <= expected_word + 1'b1;
                        if (expected_word == FRAME_WORDS - 1'b1) begin
                            published_page <= write_page; publish_toggle <= ~publish_toggle;
                            accepting_frame <= 1'b0; completed_frames <= completed_frames + 1'b1;
                        end
                        state <= GAP;
                    end
                end
                // IP 的读应答后再等一拍，采集已经稳定的 O_sdrc_data。
                READ_CAPTURE: begin
                    if (fetch_line[0]) line1[fetch_word] <= read_data;
                    else line0[fetch_word] <= read_data;
                    if (fetch_word == 9'd319) begin
                        request_done <= fetch_token;
                        completed_lines <= completed_lines + 1'b1; state <= GAP;
                    end else begin fetch_word <= fetch_word + 1'b1; state <= ACT; end
                end
                GAP: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
    // 上半字为成功保存的帧数，下半字为成功预取的行数。
    assign debug = {completed_frames, completed_lines};
endmodule
