module hdmi_top (
    input  wire clk,
    output wire dvi_txc_p,
    output wire dvi_txc_n,
    output wire dvi_tx0_p,
    output wire dvi_tx0_n,
    output wire dvi_tx1_p,
    output wire dvi_tx1_n,
    output wire dvi_tx2_p,
    output wire dvi_tx2_n,
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
    output reg io_voltage_led
);

wire clk_serial;
wire pix_clk;
wire pll_lock;

reg [7:0] red;
reg [7:0] green;
reg [7:0] blue;


// 时钟
TMDS_rPLL u_pll (
    .clkout (clk_serial),
    .lock   (pll_lock),
    .clkin  (clk)
);

// 时钟分发
CLKDIV u_clkdiv (
    .HCLKIN (clk_serial),
    .RESETN (pll_lock),
    .CALIB  (1'b1),
    .CLKOUT (pix_clk)
);
defparam u_clkdiv.DIV_MODE = "5";
defparam u_clkdiv.GSREN = "false";

wire [11:0] x, y;
wire de;
wire hs, vs;

video_timing_720p60 u_video_timing_720p60(
    .pix_clk(pix_clk),
    .rst_n  (pll_lock),
    .x      (x),
    .y      (y),
    .de     (de),
    .hsync  (hs),
    .vsync  (vs)
);

always @(*) begin
    blue = 8'b00000000;
    green = 8'b00000000;
    red  = 8'b00000000;

    if (de) begin
        if (x > 200 && x < 500 && y > 200 && y < 500) begin
            red = 8'hff;
            green = 8'h00;
            blue = 8'h00;            
        end
    end else begin
        red = 8'h00;
        green = 8'h00;
        blue = 8'h00;
    end
end

wire [2:0] tmds_data_p, tmds_data_n;

DVI_TX_Top u_dvi_tx_top(
    .I_rst_n        (pll_lock),
    .I_serial_clk   (clk_serial),
    .I_rgb_clk      (pix_clk),
    .I_rgb_vs       (vs),
    .I_rgb_hs       (hs),
    .I_rgb_de       (de),
    .I_rgb_b        (blue),
    .I_rgb_g        (green),
    .I_rgb_r        (red),
    .O_tmds_clk_p   (dvi_txc_p),
    .O_tmds_clk_n   (dvi_txc_n),
    .O_tmds_data_p  (tmds_data_p),
    .O_tmds_data_n  (tmds_data_n)
);

assign {dvi_tx2_p, dvi_tx1_p, dvi_tx0_p} = tmds_data_p;
assign {dvi_tx2_n, dvi_tx1_n, dvi_tx0_n} = tmds_data_n;

wire clk_sdram;
wire clk_sdram_tp;
wire sdram_pll_lock;
// SDRAM 108MHz 时钟
rPLL_108MHz u_rPLL_108MHz(
    .clkout(clk_sdram),
    .clkoutp(clk_sdram_tp),
    .lock(sdram_pll_lock),
    .clkin(clk)
);

wire sdrc_cmd_en;
wire [2:0] sdrc_cmd;
wire sdrc_precharge_ctrl;
wire sdram_power_down;
wire sdram_selfrefresh;
wire [20:0] sdrc_addr;
wire [3:0] sdrc_dqm;
wire [31:0] sdrc_data;
wire [7:0] sdrc_data_len;
wire [31:0] O_sdrc_data;     
wire O_sdrc_init_done;
wire O_sdrc_cmd_ack;  

assign sdrc_cmd_en = 0;
assign sdrc_cmd = 3'b111;
assign sdrc_precharge_ctrl = 1;
assign sdram_power_down = 0;
assign sdram_selfrefresh = 0;
assign sdrc_addr = 21'b0;
assign sdrc_dqm = 4'b0000;
assign sdrc_data = 32'b0;
assign sdrc_data_len = 8'b0;

SDRAM_Controller_HS_Top u_sdram(
    .O_sdram_clk            (O_sdram_clk), // SDRAM 时钟输出
    .O_sdram_cke            (O_sdram_cke), // SDRAM 时钟使能输出
    .O_sdram_cs_n           (O_sdram_cs_n), // SDRAM 片选输出，低电平有效
    .O_sdram_cas_n          (O_sdram_cas_n), // SDRAM 列地址选通输出，低电平有效
    .O_sdram_ras_n          (O_sdram_ras_n), // SDRAM 行地址选通输出，低电平有效
    .O_sdram_wen_n          (O_sdram_wen_n), // SDRAM 写使能输出，低电平有效
    .O_sdram_dqm            (O_sdram_dqm), // SDRAM 数据掩码输出 [3:0]
    .O_sdram_addr           (O_sdram_addr), // SDRAM 地址输出 [10:0]
    .O_sdram_ba             (O_sdram_ba), // SDRAM 存储体地址输出 [1:0]
    .IO_sdram_dq            (IO_sdram_dq), // SDRAM 双向数据总线 [31:0]

    .I_sdrc_rst_n           (sdram_pll_lock), // 控制器复位输入，PLL 锁定后释放
    .I_sdrc_clk             (clk_sdram), // SDRAM 控制器工作时钟输入
    .I_sdram_clk            (clk_sdram_tp), // SDRAM 工作时钟输入
    .I_sdrc_cmd_en          (sdrc_cmd_en), // 命令使能输入，高电平脉冲有效
    .I_sdrc_cmd             (sdrc_cmd), // 控制命令输入 [2:0]
    .I_sdrc_precharge_ctrl  (sdrc_precharge_ctrl), // 读写后自动预充电控制
    .I_sdram_power_down     (sdram_power_down), // SDRAM 低功耗请求输入
    .I_sdram_selfrefresh    (sdram_selfrefresh), // SDRAM 自刷新请求输入
    .I_sdrc_addr            (sdrc_addr), // SDRAM 地址输入 [20:0]
    .I_sdrc_dqm             (sdrc_dqm), // 写入数据掩码输入 [3:0]
    .I_sdrc_data            (sdrc_data), // 写入 SDRAM 的数据 [31:0]
    .I_sdrc_data_len        (sdrc_data_len), // 读写数据长度输入 [7:0]
    .O_sdrc_data            (O_sdrc_data), // SDRAM 读出数据 [31:0]
    .O_sdrc_init_done       (O_sdrc_init_done), // SDRAM 初始化完成标志
    .O_sdrc_cmd_ack         (O_sdrc_cmd_ack) // 控制命令完成应答
);

always @(posedge clk_sdram) begin
    if (O_sdrc_init_done == 1) begin
        io_voltage_led <= 1'b1;
    end else begin
        io_voltage_led <= 1'b0;
    end
end

endmodule
