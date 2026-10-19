module hdmi_top (
    input  wire clk,
    input  wire key_s1,
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
    output reg io_voltage_led0,
    output reg io_voltage_led1
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

reg sdrc_cmd_en;
reg [2:0] sdrc_cmd;
wire sdrc_precharge_ctrl;
wire sdram_power_down;
wire sdram_selfrefresh;
reg [20:0] sdrc_addr;
wire [3:0] sdrc_dqm;
reg [31:0] sdrc_data;
wire [7:0] sdrc_data_len;
wire [31:0] O_sdrc_data;
wire O_sdrc_init_done;
wire O_sdrc_cmd_ack;

assign sdrc_precharge_ctrl = 1;
assign sdram_power_down = 0;
assign sdram_selfrefresh = 0;
assign sdrc_dqm = 4'b0000;
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
    if (O_sdrc_init_done)
        io_voltage_led0 <= 1'b0;
    else
        io_voltage_led0 <= 1'b1;
end

localparam WAIT_INIT         = 4'd0;
localparam SEND_ACT          = 4'd1;
localparam WAIT_ACT_ACK      = 4'd2;
localparam SEND_WRITE        = 4'd3;
localparam WAIT_WRITE_ACK    = 4'd4;
localparam SEND_ACT_READ     = 4'd6;
localparam WAIT_ACT_READ_ACK = 4'd7;
localparam SEND_READ         = 4'd8;
localparam WAIT_READ_ACK     = 4'd9;
localparam COMPARE           = 4'd10;
localparam PASS              = 4'd11;
localparam FAIL              = 4'd12;
localparam CAPTURE_DATA      = 4'd13;

reg [3:0] sdram_state;

always @(posedge clk_sdram or negedge sdram_pll_lock) begin
    if (!sdram_pll_lock) begin
        sdram_state <= WAIT_INIT;
        io_voltage_led1 <= 1'b1;
        sdrc_cmd_en <= 1'b0;
        sdrc_cmd <= 3'b000;
        sdrc_addr <= 21'b100000;
        sdrc_data <= 32'd0;
    end else if (O_sdrc_init_done) begin
        sdrc_cmd_en <= 1'b0;
        case (sdram_state)
            WAIT_INIT: stsdram_stateate <= SEND_ACT;
            SEND_ACT: begin
                sdrc_cmd <= 3'b011;
                sdrc_addr <= 21'b100000;
                sdrc_cmd_en <= 1'b1;
                sdram_state <= WAIT_ACT_ACK;
            end
            WAIT_ACT_ACK: begin
                if (O_sdrc_cmd_ack)
                    sdram_state <= SEND_WRITE;
            end
            SEND_WRITE: begin
                sdrc_cmd <= 3'b100;
                sdrc_data <= 32'h12345678;
                sdrc_cmd_en <= 1'b1;
                sdram_state <= WAIT_WRITE_ACK;
            end
            WAIT_WRITE_ACK: begin
                if (O_sdrc_cmd_ack)
                    sdram_state <= SEND_ACT_READ;
            end
            SEND_ACT_READ: begin
                sdrc_cmd <= 3'b011;
                sdrc_cmd_en <= 1'b1;
                sdram_state <= WAIT_ACT_READ_ACK;
            end
            WAIT_ACT_READ_ACK: begin
                if (O_sdrc_cmd_ack)
                    sdram_state <= SEND_READ;
            end
            SEND_READ: begin
                sdrc_cmd <= 3'b101;
                sdrc_addr <= 21'b100000;
                sdrc_cmd_en <= 1'b1;
                sdram_state <= WAIT_READ_ACK;
            end
            WAIT_READ_ACK: begin
                if (O_sdrc_cmd_ack) begin
                    sdram_state <= CAPTURE_DATA;
                end
            end
            CAPTURE_DATA : sdram_state <= COMPARE;
            COMPARE: begin
                if (O_sdrc_data == 32'h12345678)
                    sdram_state <= PASS;
                else
                    sdram_state <= FAIL;
            end
            PASS: io_voltage_led1 <= 1'b0;
            FAIL: io_voltage_led1 <= 1'b1;
            default: sdram_state <= WAIT_INIT;
        endcase
    end
end


reg [31:0] haddr_reg;
wire [31:0] hrdata_reg;
reg hreadyin_reg;
wire hreadyout_reg;
wire hresp_reg;
reg hsel_reg;
reg [1:0] htrans_reg;
reg [31:0] hwdata_reg;
reg hwrite_reg;
reg flash_ck;
reg flash_cs_n;
reg flash_hold_n;
reg flash_wp_n;
reg flash_do;
reg flash_di;

SPI_Flash_Interface_Lite_Top u_flash(
    .I_hclk             (clk_sdram),        // 输入：AHB 总线时钟
    .I_hresetn          (sdram_pll_lock),   // 输入：AHB 总线低电平有效复位
    .I_haddr_reg        (haddr_reg),        // 输入：[31:0] AHB 寄存器地址
    .O_hrdata_reg       (hrdata_reg),       // 输出：[31:0] AHB 寄存器读数据
    .I_hreadyin_reg     (hreadyin_reg),     // 输入：AHB 主设备就绪信号
    .O_hreadyout_reg    (hreadyout_reg),    // 输出：AHB 从设备就绪信号
    .O_hresp_reg        (hresp_reg),        // 输出：[1:0] AHB 传输响应
    .I_hsel_reg         (hsel_reg),         // 输入：AHB 从设备选择信号 // 0补选中ip
    .I_htrans_reg       (htrans_reg),       // 输入：[1:0] AHB 传输类型
    .I_hwdata_reg       (hwdata_reg),       // 输入：[31:0] AHB 写数据
    .I_hwrite_reg       (hwrite_reg),       // 输入：AHB 读写控制，1 为写，0 为读
    .O_flash_ck         (flash_ck),         // 输出：SPI Flash 时钟
    .O_flash_cs_n       (flash_cs_n),       // 输出：SPI Flash 片选，低电平有效
    .IO_flash_hold_n    (flash_hold_n),     // 双向：SPI Flash 保持信号
    .IO_flash_wp_n      (flash_wp_n),       // 双向：SPI Flash 写保护信号
    .IO_flash_do        (flash_do),         // 双向：SPI Flash DO/MISO 数据线
    .IO_flash_di        (flash_di)          // 双向：SPI Flash DI/MOSI 数据线
);

localparam IDEL = 4'd0;
localparam ADDR = 4'd1;
localparam DATA = 4'd2;
localparam WAIT = 4'd3;
localparam DONE = 4'd4;

reg [3:0] flash_state;

always @(posedge clk_sdram or negedge sdram_pll_lock) begin
    if (!sdram_pll_lock) begin
        flash_state <= IDEL;
        haddr_reg <= 32'd0;
        hwdata_reg <= 32'd0;
        hsel_reg <= 0;
        htrans_reg  <= 2'b00;
        hwrite_reg  <= 1'b0;
        hreadyin_reg <= 1'b1;
    end else begin
        case (flash_state)
            IDEL : begin
                hsel_reg <= 0;
                htrans_reg <= 2'b00;
                flash_state <= ADDR;
            end 
            ADDR : begin
                hsel_reg <= 1'b1;
                haddr_reg <= 32'b0;
                htrans_reg <= 2'b10;
                flash_state <= DATA;
            end
            DATA : begin
                hwdata_reg <= 32'h12345678;
                flash_state <= WAIT;
            end
            WAIT : begin
                if (hreadyout_reg) begin
                    flash_state <= DONE;
                end
            end
            default: flash_state <= IDEL;
        endcase
    end
end

endmodule
