//==============================================================================
// SPI Flash 读写自检模块
//
// 按下 KEY_S1 后执行一次完整的只读识别和破坏性扇区读写自检：
//   1. 设置 SPI 传输格式；
//   2. 读取 JEDEC ID，排除明显的总线/引脚故障；
//   3. 擦除 TEST_ADDR 所在的 4KB 扇区；
//   4. 向 TEST_ADDR 写入 TEST_DATA；
//   5. 等待 Flash 内部 WIP 忙标志清零；
//   6. 读回 4 字节并比较。
//
// LED 指示：flash_led_n 是低电平点亮的 LED 输出。测试通过后常亮，失败时闪烁，
// 空闲或测试中熄灭。
//
// 重要：每次按键都会擦除 TEST_ADDR 起始的 4KB。默认值 0x7F0000 适用于原理图中
// 标注的 64Mbit（8MB）板载 Flash，但使用前仍要确认该扇区没有配置镜像或用户数据。
// 需要时修改顶层例化中的 TEST_ADDR；本模块绝不执行整片擦除。
//
// Gowin SPI Flash Interface Lite 寄存器偏移：
//   0x10 TransFmt，0x20 TransCtrl，0x24 Cmd，0x28 Addr，0x2C Data，0x34 Status。
// AHB 地址 0x28 是 IP 内部 Addr 寄存器；写入该寄存器的数据才是 Flash 字节地址。
//==============================================================================
module spi_flash_test #(
    parameter integer CLK_HZ = 108_000_000,
    parameter [23:0] TEST_ADDR = 24'h7F0000,
    parameter [31:0] TEST_DATA = 32'h12345678
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_s1,

    output reg         flash_led_n,
    output reg         test_busy,
    output reg         test_done,
    output reg         test_pass,
    output reg         test_fail,
    output reg  [7:0]  fail_code,
    output reg  [23:0] jedec_id,
    output reg  [31:0] readback_data,

    output wire        O_flash_ck,
    output wire        O_flash_cs_n,
    inout  wire        IO_flash_hold_n,
    inout  wire        IO_flash_wp_n,
    inout  wire        IO_flash_do,
    inout  wire        IO_flash_di
);

    // IP 内部 AHB 寄存器偏移。它们不是 Flash 存储空间的地址。
    localparam [31:0] REG_TRANSFMT  = 32'h00000010;
    localparam [31:0] REG_TRANSCTRL = 32'h00000020;
    localparam [31:0] REG_CMD       = 32'h00000024;
    localparam [31:0] REG_ADDR      = 32'h00000028;
    localparam [31:0] REG_DATA      = 32'h0000002C;
    localparam [31:0] REG_STATUS    = 32'h00000034;

    // 3 字节 Flash 地址、8 位数据、开启四字节合并、最高位优先。
    localparam [31:0] TRANSFMT_3BYTE_8BIT_4BYTE = 32'h00020780;

    // TransCtrl 的常用配置，字段含义见 Gowin SPI Flash Interface Lite 用户指南。
    localparam [31:0] CTRL_CMD_ONLY      = 32'h47000000; // 命令，无数据段
    localparam [31:0] CTRL_CMD_ADDR_ONLY = 32'h67000000; // 命令和地址，无数据段
    localparam [31:0] CTRL_READ_1BYTE    = 32'h42000000; // 命令后读取 1 字节
    localparam [31:0] CTRL_READ_JEDEC    = 32'h42000002; // 命令后读取 3 字节 JEDEC ID
    localparam [31:0] CTRL_WRITE_4BYTE   = 32'h61003000; // 命令、地址后写 4 字节
    localparam [31:0] CTRL_READ_4BYTE    = 32'h62000003; // 命令、地址后读 4 字节

    // -------------------------------------------------------------------------
    // 按键同步、消抖和启动脉冲
    // -------------------------------------------------------------------------
    // KEY_S1 是异步输入，先用两级触发器同步到 clk 时钟域。
    reg key_meta;
    reg key_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 1'b0;
            key_sync <= 1'b0;
        end else begin
            key_meta <= key_s1;
            key_sync <= key_meta;
        end
    end

    // 连续稳定 20ms 才接受按键变化，过滤机械按键抖动。
    localparam integer DEBOUNCE_CYCLES = (CLK_HZ / 1000) * 20;
    reg [31:0] debounce_count;
    reg        key_stable;
    reg        start_pulse;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debounce_count <= 32'd0;
            key_stable     <= 1'b0;
            start_pulse    <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            if (key_sync == key_stable) begin
                debounce_count <= 32'd0;
            end else if (debounce_count >= DEBOUNCE_CYCLES - 1) begin
                debounce_count <= 32'd0;
                key_stable     <= key_sync;
                // Tang Nano 20K 原理图中 KEY1 有下拉，按下视为稳定高电平。
                if (key_sync)
                    start_pulse <= 1'b1;
            end else begin
                debounce_count <= debounce_count + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Gowin SPI Flash Lite IP 的 AHB 寄存器接口
    // -------------------------------------------------------------------------
    reg  [31:0] haddr_reg;
    wire [31:0] hrdata_reg;
    wire        hreadyin_reg;
    wire        hreadyout_reg;
    wire [1:0]  hresp_reg;
    reg         hsel_reg;
    reg  [1:0]  htrans_reg;
    reg  [31:0] hwdata_reg;
    reg         hwrite_reg;

    // 主设备一直就绪；从设备通过 HREADYOUT 插入等待周期。
    assign hreadyin_reg = 1'b1;

    SPI_Flash_Interface_Lite_Top u_spi_flash_ip (
        .I_hclk          (clk),
        .I_hresetn       (rst_n),
        .I_haddr_reg     (haddr_reg),
        .O_hrdata_reg    (hrdata_reg),
        .I_hreadyin_reg  (hreadyin_reg),
        .O_hreadyout_reg (hreadyout_reg),
        .O_hresp_reg     (hresp_reg),
        .I_hsel_reg      (hsel_reg),
        .I_htrans_reg    (htrans_reg),
        .I_hwdata_reg    (hwdata_reg),
        .I_hwrite_reg    (hwrite_reg),
        .O_flash_ck      (O_flash_ck),
        .O_flash_cs_n    (O_flash_cs_n),
        .IO_flash_hold_n (IO_flash_hold_n),
        .IO_flash_wp_n   (IO_flash_wp_n),
        .IO_flash_do     (IO_flash_do),
        .IO_flash_di     (IO_flash_di)
    );

    // -------------------------------------------------------------------------
    // AHB 单次访问引擎
    // -------------------------------------------------------------------------
    // 上层每次提交一个 IP 寄存器读写请求。本引擎拆成地址阶段和数据阶段，
    // 并在 HREADYOUT=0 时保持当前阶段的信号不变。
    localparam [1:0] BUS_IDLE = 2'd0;
    localparam [1:0] BUS_ADDR = 2'd1;
    localparam [1:0] BUS_DATA = 2'd2;

    reg [1:0]  bus_state;
    reg        bus_write_latched;
    reg [31:0] bus_wdata_latched;
    reg [31:0] bus_timeout_count;
    reg        bus_done;
    reg        bus_error;
    reg [31:0] bus_rdata;

    reg        req_valid;
    reg        req_write;
    reg [31:0] req_addr;
    reg [31:0] req_wdata;
    wire       req_ready;
    assign req_ready = (bus_state == BUS_IDLE);

    localparam integer AHB_TIMEOUT_CYCLES = CLK_HZ / 10; // 100ms AHB 超时

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_state         <= BUS_IDLE;
            bus_write_latched <= 1'b0;
            bus_wdata_latched <= 32'd0;
            bus_timeout_count <= 32'd0;
            bus_done          <= 1'b0;
            bus_error         <= 1'b0;
            bus_rdata         <= 32'd0;
            haddr_reg         <= 32'd0;
            hwdata_reg        <= 32'd0;
            hsel_reg          <= 1'b0;
            htrans_reg        <= 2'b00;
            hwrite_reg        <= 1'b0;
        end else begin
            // 完成信号只保持一个周期；错误和读数据保持到下一次完成。
            bus_done <= 1'b0;
            case (bus_state)
                BUS_IDLE: begin
                    hsel_reg   <= 1'b0;
                    htrans_reg <= 2'b00; // IDLE：没有有效地址传输
                    hwdata_reg <= 32'd0;
                    if (req_valid) begin
                        // AHB 地址阶段：NONSEQ 表示一笔有效的单次传输。
                        haddr_reg         <= req_addr;
                        hwrite_reg        <= req_write;
                        bus_write_latched <= req_write;
                        bus_wdata_latched <= req_wdata;
                        hsel_reg          <= 1'b1;
                        htrans_reg        <= 2'b10;
                        bus_timeout_count <= 32'd0;
                        bus_state         <= BUS_ADDR;
                    end
                end

                BUS_ADDR: begin
                    // 从设备未就绪时，地址/控制信号继续保持有效。
                    if (hreadyout_reg) begin
                        hsel_reg   <= 1'b0;
                        htrans_reg <= 2'b00;
                        hwrite_reg <= 1'b0;
                        // AHB 写数据阶段紧随地址阶段；读请求不需要驱动 HWDATA。
                        if (bus_write_latched)
                            hwdata_reg <= bus_wdata_latched;
                        else
                            hwdata_reg <= 32'd0;
                        bus_timeout_count <= 32'd0;
                        bus_state <= BUS_DATA;
                    end else if (bus_timeout_count >= AHB_TIMEOUT_CYCLES - 1) begin
                        // 地址阶段超时，结束本次访问并通知上层失败。
                        hsel_reg          <= 1'b0;
                        htrans_reg        <= 2'b00;
                        hwrite_reg        <= 1'b0;
                        hwdata_reg        <= 32'd0;
                        bus_error         <= 1'b1;
                        bus_done          <= 1'b1;
                        bus_timeout_count <= 32'd0;
                        bus_state         <= BUS_IDLE;
                    end else begin
                        bus_timeout_count <= bus_timeout_count + 1'b1;
                    end
                end

                BUS_DATA: begin
                    // 等待写入被接受或读取数据有效；等待期间保持 HWDATA 不变。
                    if (hreadyout_reg) begin
                        bus_rdata <= hrdata_reg;
                        bus_error <= (hresp_reg != 2'b00);
                        bus_done  <= 1'b1;
                        hwdata_reg <= 32'd0;
                        bus_timeout_count <= 32'd0;
                        bus_state <= BUS_IDLE;
                    end else if (bus_timeout_count >= AHB_TIMEOUT_CYCLES - 1) begin
                        hwdata_reg        <= 32'd0;
                        bus_error         <= 1'b1;
                        bus_done          <= 1'b1;
                        bus_timeout_count <= 32'd0;
                        bus_state         <= BUS_IDLE;
                    end else begin
                        bus_timeout_count <= bus_timeout_count + 1'b1;
                    end
                end

                default: begin
                    bus_state  <= BUS_IDLE;
                    hsel_reg   <= 1'b0;
                    htrans_reg <= 2'b00;
                    hwrite_reg <= 1'b0;
                    hwdata_reg <= 32'd0;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 测试微步骤编码和请求译码
    // -------------------------------------------------------------------------
    localparam [2:0] APP_IDLE       = 3'd0;
    localparam [2:0] APP_ISSUE      = 3'd1;
    localparam [2:0] APP_WAIT_BUS   = 3'd2;
    localparam [2:0] APP_POLL_DELAY = 3'd3;

    localparam [5:0] STEP_SET_FORMAT   = 6'd0;
    localparam [5:0] STEP_JEDEC_CTRL   = 6'd1;
    localparam [5:0] STEP_JEDEC_CMD    = 6'd2;
    localparam [5:0] STEP_IP_STATUS    = 6'd3;
    localparam [5:0] STEP_JEDEC_DATA   = 6'd4;
    localparam [5:0] STEP_WREN1_CTRL   = 6'd5;
    localparam [5:0] STEP_WREN1_CMD    = 6'd6;
    localparam [5:0] STEP_ERASE_CTRL   = 6'd7;
    localparam [5:0] STEP_ERASE_ADDR   = 6'd8;
    localparam [5:0] STEP_ERASE_CMD    = 6'd9;
    localparam [5:0] STEP_WIP_CTRL     = 6'd10;
    localparam [5:0] STEP_WIP_CMD      = 6'd11;
    localparam [5:0] STEP_WIP_DATA     = 6'd12;
    localparam [5:0] STEP_WREN2_CTRL   = 6'd13;
    localparam [5:0] STEP_WREN2_CMD    = 6'd14;
    localparam [5:0] STEP_PROGRAM_CTRL = 6'd15;
    localparam [5:0] STEP_PROGRAM_DATA = 6'd16;
    localparam [5:0] STEP_PROGRAM_ADDR = 6'd17;
    localparam [5:0] STEP_PROGRAM_CMD  = 6'd18;
    localparam [5:0] STEP_READ_CTRL    = 6'd19;
    localparam [5:0] STEP_READ_ADDR    = 6'd20;
    localparam [5:0] STEP_READ_CMD     = 6'd21;
    localparam [5:0] STEP_READ_DATA    = 6'd22;

    reg [2:0]  app_state;
    reg [5:0]  step;
    reg [5:0]  after_ip_wait_step;
    reg [5:0]  after_wip_clear_step;
    reg [31:0] ip_wait_count;
    reg [31:0] poll_delay_count;
    reg [11:0] flash_poll_count;

    localparam integer IP_TIMEOUT_CYCLES = CLK_HZ;       // IP SPIActive 最长等 1 秒
    localparam integer POLL_DELAY_CYCLES = CLK_HZ / 1000; // Flash WIP 每 1ms 查询一次
    localparam integer MAX_FLASH_POLL_COUNT = 2000;      // Flash 忙等待最长约 2 秒

    // 组合逻辑把当前微步骤翻译为一笔 AHB 寄存器访问。
    always @* begin
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr  = 32'd0;
        req_wdata = 32'd0;

        if (app_state == APP_ISSUE) begin
            req_valid = 1'b1;
            case (step)
                STEP_SET_FORMAT: begin
                    req_write = 1'b1;
                    req_addr  = REG_TRANSFMT;
                    req_wdata = TRANSFMT_3BYTE_8BIT_4BYTE;
                end
                STEP_JEDEC_CTRL: begin
                    req_write = 1'b1;
                    req_addr  = REG_TRANSCTRL;
                    req_wdata = CTRL_READ_JEDEC;
                end
                STEP_JEDEC_CMD: begin
                    req_write = 1'b1;
                    req_addr  = REG_CMD;
                    req_wdata = 32'h0000009F; // JEDEC ID 命令
                end
                STEP_IP_STATUS: begin
                    req_write = 1'b0;
                    req_addr  = REG_STATUS;
                end
                STEP_JEDEC_DATA: begin
                    req_write = 1'b0;
                    req_addr  = REG_DATA;
                end
                STEP_WREN1_CTRL, STEP_WREN2_CTRL: begin
                    req_write = 1'b1;
                    req_addr  = REG_TRANSCTRL;
                    req_wdata = CTRL_CMD_ONLY;
                end
                STEP_WREN1_CMD, STEP_WREN2_CMD: begin
                    req_write = 1'b1;
                    req_addr  = REG_CMD;
                    req_wdata = 32'h00000006; // Write Enable
                end
                STEP_ERASE_CTRL: begin
                    req_write = 1'b1;
                    req_addr  = REG_TRANSCTRL;
                    req_wdata = CTRL_CMD_ADDR_ONLY;
                end
                STEP_ERASE_ADDR: begin
                    req_write = 1'b1;
                    req_addr  = REG_ADDR;
                    req_wdata = {8'd0, TEST_ADDR};
                end
                STEP_ERASE_CMD: begin
                    req_write = 1'b1;
                    req_addr  = REG_CMD;
                    req_wdata = 32'h00000020; // 4KB Sector Erase
                end
                STEP_WIP_CTRL: begin
                    req_write = 1'b1;
                    req_addr  = REG_TRANSCTRL;
                    req_wdata = CTRL_READ_1BYTE;
                end
                STEP_WIP_CMD: begin
                    req_write = 1'b1;
                    req_addr  = REG_CMD;
                    req_wdata = 32'h00000005; // 读状态寄存器 1
                end
                STEP_WIP_DATA: begin
                    req_write = 1'b0;
                    req_addr  = REG_DATA;
                end
                STEP_PROGRAM_CTRL: begin
                    req_write = 1'b1;
                    req_addr  = REG_TRANSCTRL;
                    req_wdata = CTRL_WRITE_4BYTE;
                end
                STEP_PROGRAM_DATA: begin
                    req_write = 1'b1;
                    req_addr  = REG_DATA;
                    req_wdata = TEST_DATA;
                end
                STEP_PROGRAM_ADDR: begin
                    req_write = 1'b1;
                    req_addr  = REG_ADDR;
                    req_wdata = {8'd0, TEST_ADDR};
                end
                STEP_PROGRAM_CMD: begin
                    req_write = 1'b1;
                    req_addr  = REG_CMD;
                    req_wdata = 32'h00000002; // Page Program
                end
                STEP_READ_CTRL: begin
                    req_write = 1'b1;
                    req_addr  = REG_TRANSCTRL;
                    req_wdata = CTRL_READ_4BYTE;
                end
                STEP_READ_ADDR: begin
                    req_write = 1'b1;
                    req_addr  = REG_ADDR;
                    req_wdata = {8'd0, TEST_ADDR};
                end
                STEP_READ_CMD: begin
                    req_write = 1'b1;
                    req_addr  = REG_CMD;
                    req_wdata = 32'h00000003; // Read Data
                end
                STEP_READ_DATA: begin
                    req_write = 1'b0;
                    req_addr  = REG_DATA;
                end
                default: begin
                    req_valid = 1'b0;
                    req_write = 1'b0;
                    req_addr  = 32'd0;
                    req_wdata = 32'd0;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 自检主状态机
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            app_state            <= APP_IDLE;
            step                 <= STEP_SET_FORMAT;
            after_ip_wait_step   <= STEP_JEDEC_DATA;
            after_wip_clear_step <= STEP_WREN2_CTRL;
            ip_wait_count        <= 32'd0;
            poll_delay_count     <= 32'd0;
            flash_poll_count     <= 12'd0;
            test_busy            <= 1'b0;
            test_done            <= 1'b0;
            test_pass            <= 1'b0;
            test_fail            <= 1'b0;
            fail_code            <= 8'h00;
            jedec_id              <= 24'd0;
            readback_data         <= 32'd0;
        end else begin
            case (app_state)
                APP_IDLE: begin
                    if (start_pulse) begin
                        // 开始新一轮时清除旧结果，然后从传输格式寄存器开始配置。
                        test_busy         <= 1'b1;
                        test_done         <= 1'b0;
                        test_pass         <= 1'b0;
                        test_fail         <= 1'b0;
                        fail_code         <= 8'h00;
                        jedec_id          <= 24'd0;
                        readback_data     <= 32'd0;
                        flash_poll_count  <= 12'd0;
                        ip_wait_count     <= 32'd0;
                        step              <= STEP_SET_FORMAT;
                        app_state         <= APP_ISSUE;
                    end
                end

                APP_ISSUE: begin
                    // req_valid 在该状态保持为 1，直到空闲的 AHB 引擎接收请求。
                    if (req_valid && req_ready)
                        app_state <= APP_WAIT_BUS;
                end

                APP_WAIT_BUS: begin
                    if (bus_done) begin
                        if (bus_error) begin
                            // AHB 响应异常或 AHB 等待超时。
                            test_busy <= 1'b0;
                            test_done <= 1'b1;
                            test_fail <= 1'b1;
                            fail_code <= 8'h04;
                            app_state <= APP_IDLE;
                        end else begin
                            case (step)
                                STEP_SET_FORMAT: begin
                                    step      <= STEP_JEDEC_CTRL;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_JEDEC_CTRL: begin
                                    step      <= STEP_JEDEC_CMD;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_JEDEC_CMD: begin
                                    // 写 Cmd 启动 SPI 传输；先等待 IP 的 SPIActive 清零。
                                    after_ip_wait_step <= STEP_JEDEC_DATA;
                                    ip_wait_count      <= 32'd0;
                                    step               <= STEP_IP_STATUS;
                                    app_state          <= APP_ISSUE;
                                end
                                STEP_IP_STATUS: begin
                                    if (bus_rdata[0]) begin
                                        // SPIActive=1 表示 IP 还在移位传输。
                                        if (ip_wait_count >= IP_TIMEOUT_CYCLES - 1) begin
                                            test_busy <= 1'b0;
                                            test_done <= 1'b1;
                                            test_fail <= 1'b1;
                                            fail_code <= 8'h02;
                                            app_state <= APP_IDLE;
                                        end else begin
                                            ip_wait_count <= ip_wait_count + 1'b1;
                                            app_state     <= APP_ISSUE;
                                        end
                                    end else begin
                                        // IP 传输已结束，转入对应的下一步。
                                        ip_wait_count <= 32'd0;
                                        step          <= after_ip_wait_step;
                                        app_state     <= APP_ISSUE;
                                    end
                                end
                                STEP_JEDEC_DATA: begin
                                    jedec_id <= bus_rdata[23:0];
                                    // 全 0 或全 1 通常表示数据线、片选或管脚映射有问题。
                                    if ((bus_rdata[23:0] == 24'h000000) ||
                                        (bus_rdata[23:0] == 24'hFFFFFF)) begin
                                        test_busy <= 1'b0;
                                        test_done <= 1'b1;
                                        test_fail <= 1'b1;
                                        fail_code <= 8'h01;
                                        app_state <= APP_IDLE;
                                    end else begin
                                        step      <= STEP_WREN1_CTRL;
                                        app_state <= APP_ISSUE;
                                    end
                                end
                                STEP_WREN1_CTRL: begin
                                    step      <= STEP_WREN1_CMD;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_WREN1_CMD: begin
                                    after_ip_wait_step <= STEP_ERASE_CTRL;
                                    ip_wait_count      <= 32'd0;
                                    step               <= STEP_IP_STATUS;
                                    app_state          <= APP_ISSUE;
                                end
                                STEP_ERASE_CTRL: begin
                                    step      <= STEP_ERASE_ADDR;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_ERASE_ADDR: begin
                                    step      <= STEP_ERASE_CMD;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_ERASE_CMD: begin
                                    // SPI 擦除命令传完后，Flash 芯片内部还需要较长时间擦除。
                                    after_ip_wait_step   <= STEP_WIP_CTRL;
                                    after_wip_clear_step <= STEP_WREN2_CTRL;
                                    ip_wait_count        <= 32'd0;
                                    step                 <= STEP_IP_STATUS;
                                    app_state            <= APP_ISSUE;
                                end
                                STEP_WIP_CTRL: begin
                                    step      <= STEP_WIP_CMD;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_WIP_CMD: begin
                                    after_ip_wait_step <= STEP_WIP_DATA;
                                    ip_wait_count      <= 32'd0;
                                    step               <= STEP_IP_STATUS;
                                    app_state          <= APP_ISSUE;
                                end
                                STEP_WIP_DATA: begin
                                    if (bus_rdata[0]) begin
                                        // WIP=1：Flash 芯片仍在执行擦除或编程。
                                        if (flash_poll_count >= MAX_FLASH_POLL_COUNT) begin
                                            test_busy <= 1'b0;
                                            test_done <= 1'b1;
                                            test_fail <= 1'b1;
                                            fail_code <= 8'h03;
                                            app_state <= APP_IDLE;
                                        end else begin
                                            flash_poll_count <= flash_poll_count + 1'b1;
                                            poll_delay_count <= 32'd0;
                                            app_state        <= APP_POLL_DELAY;
                                        end
                                    end else begin
                                        // WIP=0：当前内部操作结束，进入下一阶段。
                                        flash_poll_count <= 12'd0;
                                        step             <= after_wip_clear_step;
                                        app_state        <= APP_ISSUE;
                                    end
                                end
                                STEP_WREN2_CTRL: begin
                                    step      <= STEP_WREN2_CMD;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_WREN2_CMD: begin
                                    after_ip_wait_step <= STEP_PROGRAM_CTRL;
                                    ip_wait_count      <= 32'd0;
                                    step               <= STEP_IP_STATUS;
                                    app_state          <= APP_ISSUE;
                                end
                                STEP_PROGRAM_CTRL: begin
                                    step      <= STEP_PROGRAM_DATA;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_PROGRAM_DATA: begin
                                    step      <= STEP_PROGRAM_ADDR;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_PROGRAM_ADDR: begin
                                    step      <= STEP_PROGRAM_CMD;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_PROGRAM_CMD: begin
                                    after_ip_wait_step   <= STEP_WIP_CTRL;
                                    after_wip_clear_step <= STEP_READ_CTRL;
                                    ip_wait_count        <= 32'd0;
                                    step                 <= STEP_IP_STATUS;
                                    app_state            <= APP_ISSUE;
                                end
                                STEP_READ_CTRL: begin
                                    step      <= STEP_READ_ADDR;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_READ_ADDR: begin
                                    step      <= STEP_READ_CMD;
                                    app_state <= APP_ISSUE;
                                end
                                STEP_READ_CMD: begin
                                    after_ip_wait_step <= STEP_READ_DATA;
                                    ip_wait_count      <= 32'd0;
                                    step               <= STEP_IP_STATUS;
                                    app_state          <= APP_ISSUE;
                                end
                                STEP_READ_DATA: begin
                                    // 保存读回值，和本轮写入数据比较并锁存结果。
                                    readback_data <= bus_rdata;
                                    test_busy     <= 1'b0;
                                    test_done     <= 1'b1;
                                    if (bus_rdata == TEST_DATA)
                                        test_pass <= 1'b1;
                                    else begin
                                        test_fail <= 1'b1;
                                        fail_code <= 8'h05;
                                    end
                                    app_state <= APP_IDLE;
                                end
                                default: begin
                                    test_busy <= 1'b0;
                                    test_done <= 1'b1;
                                    test_fail <= 1'b1;
                                    fail_code <= 8'hFF;
                                    app_state <= APP_IDLE;
                                end
                            endcase
                        end
                    end
                end

                APP_POLL_DELAY: begin
                    // WIP 仍为 1 时，等待约 1ms 后再发起下一次状态寄存器读取。
                    if (poll_delay_count >= POLL_DELAY_CYCLES - 1) begin
                        poll_delay_count <= 32'd0;
                        step             <= STEP_WIP_CTRL;
                        app_state        <= APP_ISSUE;
                    end else begin
                        poll_delay_count <= poll_delay_count + 1'b1;
                    end
                end

                default: begin
                    app_state <= APP_IDLE;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // LED2 结果显示（板载 LED 低电平点亮）
    // -------------------------------------------------------------------------
    reg [25:0] led_blink_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            led_blink_count <= 26'd0;
            flash_led_n     <= 1'b1; // 复位时熄灭
        end else begin
            led_blink_count <= led_blink_count + 1'b1;
            if (test_pass)
                flash_led_n <= 1'b0; // 常亮：读回比较正确
            else if (test_fail)
                flash_led_n <= led_blink_count[24]; // 闪烁：识别、总线或读回失败
            else
                flash_led_n <= 1'b1; // 熄灭：空闲或测试中
        end
    end

endmodule
