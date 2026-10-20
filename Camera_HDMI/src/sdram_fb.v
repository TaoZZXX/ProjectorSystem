// 640x360 RGB565 -> SDRAM -> 双行缓存 -> 2 倍放大铺满 1280x720。
// 包含 108 MHz PLL、SDRAM 控制器、异步 FIFO、命令仲裁与行缓存。
module sdram_fb (
    input  wire        clk,          // 27 MHz
    input  wire        pll_lock_27,
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq,
    // 摄像头原始像素流
    input  wire        cam_pclk,
    input  wire        cam_valid,
    input  wire [15:0] cam_pix,
    input  wire        cam_sof,
    // 显示
    input  wire        pix_clk,
    input  wire [11:0] x,
    input  wire [11:0] y,
    output wire [15:0] pix_out,
    output wire        frame_ok,
    output wire [31:0] dbg
);
    // ---------------- 108 MHz 时钟与粘滞复位 ----------------
    wire clk_sdram, clk_sdram_tp, sdram_pll_lock;
    rPLL_108MHz u_rpll (
        .clkout(clk_sdram), .clkoutp(clk_sdram_tp),
        .lock(sdram_pll_lock), .clkin(clk)
    );

    reg [1:0] lk_sync;
    reg [7:0] lk_cnt;
    reg       run;
    always @(posedge clk or negedge pll_lock_27) begin
        if (!pll_lock_27) begin
            lk_sync <= 2'b00; lk_cnt <= 8'd0; run <= 1'b0;
        end else begin
            lk_sync <= {lk_sync[0], sdram_pll_lock};
            if (!lk_sync[1]) lk_cnt <= 8'd0;
            else if (lk_cnt != 8'hff) begin
                lk_cnt <= lk_cnt + 1'b1;
                if (lk_cnt == 8'hfe) run <= 1'b1;
            end
        end
    end

    reg        cmd_en;
    reg  [2:0] cmd;
    reg  [20:0] addr;
    reg  [31:0] wdata;
    wire [31:0] rdata;
    wire        ack;
    wire        init_done;

    SDRAM_Controller_HS_Top u_sdram (
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm), .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba), .IO_sdram_dq(IO_sdram_dq),
        .I_sdrc_rst_n(run),
        .I_sdrc_clk(clk_sdram), .I_sdram_clk(clk_sdram_tp),
        .I_sdrc_cmd_en(cmd_en), .I_sdrc_cmd(cmd),
        .I_sdrc_precharge_ctrl(1'b1),
        .I_sdram_power_down(1'b0), .I_sdram_selfrefresh(1'b0),
        .I_sdrc_addr(addr), .I_sdrc_dqm(4'b0000),
        .I_sdrc_data(wdata), .I_sdrc_data_len(8'd0),
        .O_sdrc_data(rdata), .O_sdrc_init_done(init_done),
        .O_sdrc_cmd_ack(ack)
    );

    // ---------------- 异步 FIFO 256x32 ----------------
    reg [31:0] fmem [0:255];
    reg [7:0]  wbin, wgray, rbin, rgray;
    reg [7:0]  wg_s1, wg_s2;       // 写指针灰度同步到读域
    reg [7:0]  rg_s1, rg_s2;       // 读指针灰度同步到写域
    reg        half;
    reg [15:0] low_pix;

    wire [7:0] wbin_n  = wbin + 1'b1;
    wire [7:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
    wire [7:0] rbin_n  = rbin + 1'b1;
    wire [7:0] rgray_n = (rbin_n >> 1) ^ rbin_n;
    wire fifo_full  = (wgray_n == {~rg_s2[7:6], rg_s2[5:0]});
    wire fifo_empty = (rgray == wg_s2);

    always @(posedge cam_pclk) begin
        rg_s1 <= rgray;
        rg_s2 <= rg_s1;
        if (cam_valid) begin
            if (!half) begin
                low_pix <= cam_pix;
                half <= 1'b1;
            end else begin
                half <= 1'b0;
                if (!fifo_full) begin
                    fmem[wbin] <= {cam_pix, low_pix};
                    wbin  <= wbin_n;
                    wgray <= wgray_n;
                end
            end
        end
        if (cam_sof) half <= 1'b0;
    end

    // ---------------- 帧首跨域 ----------------
    reg sof_tgl;
    always @(posedge cam_pclk) if (cam_sof) sof_tgl <= ~sof_tgl;
    reg sof_s1, sof_s2, sof_s2_d;
    always @(posedge clk_sdram) begin
        sof_s1 <= sof_tgl;
        sof_s2 <= sof_s1;
    end

    // ---------------- 取行请求跨域 ----------------
    reg        ftgl;
    reg [9:0]  fline;
    reg        ftgl_s1, ftgl_s2;
    reg [9:0]  fline_s;
    always @(posedge clk_sdram) begin
        ftgl_s1 <= ftgl;
        ftgl_s2 <= ftgl_s1;
    end

    // ---------------- 命令引擎 ----------------
    localparam [2:0] E_IDLE = 3'd0, E_FACT = 3'd1, E_FACT_A = 3'd2,
                     E_FRD_A = 3'd3, E_WACT = 3'd4, E_WACT_A = 3'd5,
                     E_WWR_A = 3'd6;
    reg [2:0]  est;
    reg [8:0]  fi;
    reg [16:0] wr_ptr;
    reg wr_base, rd_base;
    reg [31:0] fifo_q;
    reg        done_tgl;
    reg        req_lat;

    (* syn_ramstyle = "block_ram" *) reg [31:0] lb0 [0:319];
    (* syn_ramstyle = "block_ram" *) reg [31:0] lb1 [0:319];

    always @(posedge clk_sdram or negedge run) begin
        if (!run) begin
            est <= E_IDLE; cmd_en <= 1'b0; cmd <= 3'b000;
            addr <= 21'd0; wdata <= 32'd0;
            fi <= 9'd0; wr_ptr <= 17'd0; wr_base <= 1'b0; rd_base <= 1'b0;
            rbin <= 8'd0; rgray <= 8'd0;
            wg_s1 <= 8'd0; wg_s2 <= 8'd0;
            fifo_q <= 32'd0; done_tgl <= 1'b0; frame_words <= 17'd0; fc <= 16'd0; win <= 27'd0; fetch_rate <= 16'd0; req_lat <= 1'b0;
            fline_s <= 10'd0; sof_s2_d <= 1'b0;
        end else begin
            cmd_en <= 1'b0;
            wg_s1 <= wgray;
            wg_s2 <= wg_s1;

            // 帧首：写指针回零
            sof_s2_d <= sof_s2;
            if (sof_s2 ^ sof_s2_d) begin
                frame_words <= wr_ptr;
                rd_base <= wr_base;
                wr_base <= ~wr_base;
                wr_ptr <= 17'd0;
            end

            if (win == 27'd107_999_999) begin
                win <= 27'd0;
                fetch_rate <= fc;
                fc <= 16'd0;
            end else win <= win + 1'b1;

            case (est)
                E_IDLE: begin
                    if (!init_done) begin
                        est <= E_IDLE;
                    end else if (ftgl_s2 != done_tgl) begin
                        fi <= 9'd0;
                        fline_s <= fline;
                        req_lat <= ftgl_s2;
                        est <= E_FACT;
                    end else if (!fifo_empty) begin
                        fifo_q <= fmem[rbin];
                        est <= E_WACT;
                    end
                end
                E_FACT: begin
                    cmd <= 3'b011;
                    addr <= (rd_base ? 21'd115200 : 21'd0) +
                            {5'd0, fline_s} * 21'd320 + {12'd0, fi};
                    cmd_en <= 1'b1;
                    est <= E_FACT_A;
                end
                E_FACT_A: if (ack) begin
                    cmd <= 3'b101; cmd_en <= 1'b1;
                    est <= E_FRD_A;
                end
                E_FRD_A: if (ack) begin
                    if (fline_s[0]) lb1[fi] <= rdata;
                    else            lb0[fi] <= rdata;
                    fi <= fi + 1'b1;
                    if (fi == 9'd319) begin
                        done_tgl <= req_lat;
                        if (fc != 16'hffff) fc <= fc + 1'b1;
                        est <= E_IDLE;
                    end else est <= E_FACT;
                end
                E_WACT: begin
                    cmd <= 3'b011;
                    addr <= (wr_base ? 21'd115200 : 21'd0) + {4'd0, wr_ptr};
                    cmd_en <= 1'b1;
                    est <= E_WACT_A;
                end
                E_WACT_A: if (ack) begin
                    cmd <= 3'b100; wdata <= fifo_q; cmd_en <= 1'b1;
                    est <= E_WWR_A;
                end
                E_WWR_A: if (ack) begin
                    wr_ptr <= wr_ptr + 1'b1;
                    rbin <= rbin_n;
                    rgray <= rgray_n;
                    est <= E_IDLE;
                end
                default: est <= E_IDLE;
            endcase
        end
    end

    // ---------------- 显示侧 ----------------
    wire [9:0] sx = (x >> 1);
    wire [9:0] sxn = ((x + 1'b1) > 12'd1279) ? 10'd639 : ((x + 1'b1) >> 1);
    wire [8:0] sy = y >> 1;

    reg [31:0] lb_q;
    reg        half_q;
    always @(posedge pix_clk) begin
        if (sy[0]) lb_q <= lb1[sxn[9:1]];
        else       lb_q <= lb0[sxn[9:1]];
        half_q <= sxn[0];
    end
    // 临时自检图案：R = 源行号、GB = 源列号，用来单点验证显示寻址与 2 倍缩放
    assign pix_out = half_q ? lb_q[31:16] : lb_q[15:0];

    // 取行请求：每开始一条新的源行请求下一行；场消隐请求第 0 行
    always @(posedge pix_clk) begin
        if (y == 12'd720 && x == 12'd0) begin
            fline <= 10'd0;
            ftgl  <= ~ftgl;
        end else if (x == 12'd0 && y < 12'd720 && (y[0] == 1'b0)) begin
            fline <= (y >> 1) + 10'd1;
            ftgl  <= ~ftgl;
        end
    end

    assign frame_ok = init_done;
    reg [9:0] cap_cnt;
    always @(posedge cam_pclk)
        if (cam_valid && cap_cnt != 10'h3ff) cap_cnt <= cap_cnt + 1'b1;
    reg [16:0] frame_words;
    reg [15:0] fc;
    reg [26:0] win;
    reg [15:0] fetch_rate;
    assign dbg = {fetch_rate, frame_words[15:0]};
endmodule
