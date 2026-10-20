// SDRAM 通路探针：108 MHz PLL + 控制器 + 单字读写自检 + 读吞吐基准。
// 诊断输出：
//   probe_result = clk_sdram 域自由运行计数器（相邻两次上报的差值应≈216e6）
//   probe_code   = {进入过基准, 自检通过, 2'b0, 状态机 4 位状态}
module sdram_probe (
    input  wire        clk,
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
    output wire [31:0] probe_result,
    output wire [7:0]  probe_code
);
    wire clk_sdram, clk_sdram_tp, sdram_pll_lock;
    rPLL_108MHz u_rpll_sdram (
        .clkout(clk_sdram), .clkoutp(clk_sdram_tp),
        .lock(sdram_pll_lock), .clkin(clk)
    );

    // 粘滞复位：27 MHz 域连续看到锁定 254 拍后释放，之后 lock 抖动不再复位。
    reg [1:0] lock_sync;
    reg [7:0] lock_cnt;
    reg       sdram_run;
    always @(posedge clk or negedge pll_lock_27) begin
        if (!pll_lock_27) begin
            lock_sync <= 2'b00;
            lock_cnt  <= 8'd0;
            sdram_run <= 1'b0;
        end else begin
            lock_sync <= {lock_sync[0], sdram_pll_lock};
            if (!lock_sync[1]) begin
                lock_cnt <= 8'd0;
            end else if (lock_cnt != 8'hff) begin
                lock_cnt <= lock_cnt + 1'b1;
                if (lock_cnt == 8'hfe) sdram_run <= 1'b1;
            end
        end
    end

    reg         cmd_en;
    reg  [2:0]  cmd;
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
        .I_sdrc_rst_n(sdram_run),
        .I_sdrc_clk(clk_sdram), .I_sdram_clk(clk_sdram_tp),
        .I_sdrc_cmd_en(cmd_en), .I_sdrc_cmd(cmd),
        .I_sdrc_precharge_ctrl(1'b1),
        .I_sdram_power_down(1'b0), .I_sdram_selfrefresh(1'b0),
        .I_sdrc_addr(addr), .I_sdrc_dqm(4'b0000),
        .I_sdrc_data(wdata), .I_sdrc_data_len(8'd0),
        .O_sdrc_data(rdata), .O_sdrc_init_done(init_done),
        .O_sdrc_cmd_ack(ack)
    );

    reg [26:0] bench_win;
    reg [31:0] bench_result;
    reg [31:0] free_cnt;
    always @(posedge clk_sdram or negedge sdram_run) begin
        if (!sdram_run) free_cnt <= 32'd0;
        else            free_cnt <= free_cnt + 1'b1;
    end
    always @(posedge clk_sdram or negedge sdram_run) begin
        if (!sdram_run) begin
            bench_win <= 27'd0;
            bench_result <= 32'd0;
        end else if (bench_win == 27'd107_999_999) begin
            bench_win <= 27'd0;
            bench_result <= bench_cnt;
        end else begin
            bench_win <= bench_win + 1'b1;
        end
    end
    assign probe_result = bench_result;

    localparam [3:0] T_INIT = 4'd0, T_ACT = 4'd1, T_ACT_A = 4'd2,
                     T_WR_A = 4'd3, T_ACT2_A = 4'd4, T_RD_A = 4'd5,
                     T_CAP = 4'd6, T_CMP = 4'd7, T_BGAP = 4'd8,
                     T_BACT = 4'd9, T_BACT_A = 4'd10, T_BRD_A = 4'd11,
                     T_BGAP2 = 4'd12;
    reg [3:0]  st;
    reg [31:0] test_rdata;
    reg        test_ok;
    reg        bench_entered;
    reg [31:0] bench_cnt;
    reg [7:0]  gap;

    assign probe_code = {bench_entered, test_ok, 2'b00, st};

    always @(posedge clk_sdram or negedge sdram_run) begin
        if (!sdram_run) begin
            st <= T_INIT;
            cmd_en <= 1'b0; cmd <= 3'b000; addr <= 21'h100000; wdata <= 32'd0;
            test_rdata <= 32'd0; test_ok <= 1'b0;
            bench_entered <= 1'b0; bench_cnt <= 32'd0;
            gap <= 8'd0;
        end else begin
            cmd_en <= 1'b0;
            case (st)
                T_INIT: if (init_done) begin gap <= 8'd0; st <= T_BGAP; end
                T_BGAP: begin
                    // 32 拍间隔后进入自检
                    if (gap == 8'd31) begin gap <= 8'd0; st <= T_ACT; end
                    else gap <= gap + 1'b1;
                end
                T_ACT: begin
                    cmd <= 3'b011; addr <= 21'h100000; cmd_en <= 1'b1;
                    st <= T_ACT_A;
                end
                T_ACT_A: if (ack) begin
                    cmd <= 3'b100; wdata <= 32'h12345678; cmd_en <= 1'b1;
                    st <= T_WR_A;
                end
                T_WR_A: if (ack) begin
                    cmd <= 3'b011; cmd_en <= 1'b1;
                    st <= T_ACT2_A;
                end
                T_ACT2_A: if (ack) begin
                    cmd <= 3'b101; addr <= 21'h100000; cmd_en <= 1'b1;
                    st <= T_RD_A;
                end
                T_RD_A: if (ack) st <= T_CAP;
                T_CAP: begin
                    test_rdata <= rdata;
                    st <= T_CMP;
                end
                T_CMP: begin
                    test_ok <= (test_rdata == 32'h12345678);
                    gap <= 8'd0;
                    st <= (test_rdata == 32'h12345678) ? T_BGAP2 : T_INIT;
                end
                T_BGAP2: begin
                    bench_entered <= 1'b1;
                    if (gap == 8'd31) begin gap <= 8'd0; st <= T_BACT; end
                    else gap <= gap + 1'b1;
                end
                T_BACT: begin
                    cmd <= 3'b011; addr <= 21'h100000; cmd_en <= 1'b1;
                    st <= T_BACT_A;
                end
                T_BACT_A: if (ack) begin
                    cmd <= 3'b101; addr <= 21'h100000; cmd_en <= 1'b1;
                    st <= T_BRD_A;
                end
                T_BRD_A: if (ack) begin
                    if (bench_cnt != 32'hffffffff) bench_cnt <= bench_cnt + 1'b1;
                    st <= T_BACT;
                end
                default: st <= T_INIT;
            endcase
        end
    end
endmodule
