//==============================================================================
// SPI Flash 自检结果 UART 输出模块
//
// 每当 report_valid 从 0 变成测试完成状态（高电平）时，只发送一行：
// ID=EF4017 RB=12345678 EXP=12345678 PASS CODE=00\r\n
// 串口格式：115200 baud、8 数据位、无校验、1 停止位（8N1）。
// 本模块按 CLK_HZ 四舍五入计算每位时钟数。108 MHz 时每位 938 个时钟，
// 实际波特率约 115.14 kbaud，与 115200 baud 的误差小于 0.1%。
//
// CODE 失败码：
//   00：通过
//   01：JEDEC ID 为全 0 或全 1，Flash 无有效响应
//   02：等待 SPI Flash IP 的 SPIActive 清零超时
//   03：Flash 的 WIP 忙标志等待超时
//   04：AHB 寄存器访问错误或超时
//   05：Flash 读回值与写入值不一致
//   FF：状态机进入未定义步骤
//==============================================================================
module uart_hex_report #(
    parameter integer CLK_HZ   = 108_000_000,
    parameter integer UART_BAUD = 115_200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        report_valid,
    input  wire        report_pass,
    input  wire [7:0]  fail_code,
    input  wire [23:0] jedec_id,
    input  wire [31:0] readback_data,
    input  wire [31:0] expected_data,
    output reg         uart_tx
);

    // UART 一位的时钟周期数。四舍五入可减小整数分频误差。
    localparam integer CLKS_PER_BIT =
        (CLK_HZ + (UART_BAUD / 2)) / UART_BAUD;

    localparam [2:0] TX_IDLE  = 3'd0;
    localparam [2:0] TX_LOAD  = 3'd1;
    localparam [2:0] TX_START = 3'd2;
    localparam [2:0] TX_DATA  = 3'd3;
    localparam [2:0] TX_STOP  = 3'd4;

    // 固定长度 49 字节：
    // ID=xxxxxx RB=xxxxxxxx EXP=xxxxxxxx PASS/FAIL CODE=xx\r\n
    localparam [5:0] REPORT_LENGTH = 6'd49;

    reg [2:0]  tx_state;
    reg [31:0] baud_count;
    reg [5:0]  char_index;
    reg [2:0]  bit_index;
    reg [7:0]  tx_byte;
    reg [7:0]  tx_shift;
    reg        report_sent;

    // 测试完成时锁存数据，保证整行输出期间内容稳定。
    reg        pass_latched;
    reg [7:0]  code_latched;
    reg [23:0] id_latched;
    reg [31:0] read_latched;
    reg [31:0] expected_latched;

    // 4 位数值转换为一个大写十六进制 ASCII 字符。
    function [7:0] hex_ascii;
        input [3:0] value;
        begin
            if (value < 4'd10)
                hex_ascii = 8'h30 + value; // '0' 到 '9'
            else
                hex_ascii = 8'h41 + (value - 4'd10); // 'A' 到 'F'
        end
    endfunction

    // 根据字符序号生成报告中的一个 ASCII 字符。
    function [7:0] report_char;
        input [5:0]  position;
        input [23:0] id_value;
        input [31:0] read_value;
        input [31:0] expected_value;
        input        passed;
        input [7:0]  code_value;
        integer      bit_shift;
        begin
            case (position)
                6'd0:  report_char = "I";
                6'd1:  report_char = "D";
                6'd2:  report_char = "=";
                6'd9:  report_char = " ";
                6'd10: report_char = "R";
                6'd11: report_char = "B";
                6'd12: report_char = "=";
                6'd21: report_char = " ";
                6'd22: report_char = "E";
                6'd23: report_char = "X";
                6'd24: report_char = "P";
                6'd25: report_char = "=";
                6'd34: report_char = " ";
                6'd35: report_char = passed ? "P" : "F";
                6'd36: report_char = passed ? "A" : "A";
                6'd37: report_char = passed ? "S" : "I";
                6'd38: report_char = passed ? "S" : "L";
                6'd39: report_char = " ";
                6'd40: report_char = "C";
                6'd41: report_char = "O";
                6'd42: report_char = "D";
                6'd43: report_char = "E";
                6'd44: report_char = "=";
                6'd47: report_char = 8'h0D; // 回车
                6'd48: report_char = 8'h0A; // 换行
                default: begin
                    if ((position >= 6'd3) && (position <= 6'd8)) begin
                        // JEDEC ID 共 6 个十六进制字符，高位先发。
                        bit_shift = (8 - position) * 4;
                        report_char = hex_ascii((id_value >> bit_shift) & 4'hF);
                    end else if ((position >= 6'd13) && (position <= 6'd20)) begin
                        // 读回数据共 8 个十六进制字符，高位先发。
                        bit_shift = (20 - position) * 4;
                        report_char = hex_ascii((read_value >> bit_shift) & 4'hF);
                    end else if ((position >= 6'd26) && (position <= 6'd33)) begin
                        // 期望数据共 8 个十六进制字符，高位先发。
                        bit_shift = (33 - position) * 4;
                        report_char = hex_ascii((expected_value >> bit_shift) & 4'hF);
                    end else if ((position == 6'd45) || (position == 6'd46)) begin
                        // 失败码输出为两个十六进制字符。
                        bit_shift = (46 - position) * 4;
                        report_char = hex_ascii((code_value >> bit_shift) & 4'hF);
                    end else begin
                        report_char = 8'h3F; // 未覆盖的位置显示问号，便于发现格式错误
                    end
                end
            endcase
        end
    endfunction

    // UART 发送状态机：每个字符按起始位、8 个数据位、停止位发送。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state        <= TX_IDLE;
            baud_count      <= 32'd0;
            char_index      <= 6'd0;
            bit_index       <= 3'd0;
            tx_byte         <= 8'd0;
            tx_shift        <= 8'd0;
            uart_tx         <= 1'b1; // UART 空闲电平为高
            report_sent     <= 1'b0;
            pass_latched    <= 1'b0;
            code_latched    <= 8'd0;
            id_latched      <= 24'd0;
            read_latched    <= 32'd0;
            expected_latched <= 32'd0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    uart_tx    <= 1'b1;
                    baud_count <= 32'd0;

                    // report_valid 在自检开始时会清零，借此允许下一轮重新上报。
                    if (!report_valid)
                        report_sent <= 1'b0;
                    else if (!report_sent) begin
                        pass_latched     <= report_pass;
                        code_latched     <= fail_code;
                        id_latched       <= jedec_id;
                        read_latched     <= readback_data;
                        expected_latched <= expected_data;
                        char_index       <= 6'd0;
                        report_sent      <= 1'b1;
                        tx_state         <= TX_LOAD;
                    end
                end

                TX_LOAD: begin
                    // 当前状态下取出一字节，然后拉低 TX 发送起始位。
                    tx_byte    <= report_char(char_index, id_latched,
                                               read_latched, expected_latched,
                                               pass_latched, code_latched);
                    uart_tx    <= 1'b0;
                    baud_count <= 32'd0;
                    tx_state   <= TX_START;
                end

                TX_START: begin
                    if (baud_count >= CLKS_PER_BIT - 1) begin
                        baud_count <= 32'd0;
                        bit_index  <= 3'd0;
                        tx_shift   <= {1'b0, tx_byte[7:1]};
                        uart_tx    <= tx_byte[0]; // UART 数据位从最低位开始
                        tx_state   <= TX_DATA;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                TX_DATA: begin
                    if (baud_count >= CLKS_PER_BIT - 1) begin
                        baud_count <= 32'd0;
                        if (bit_index == 3'd7) begin
                            uart_tx  <= 1'b1; // 停止位
                            tx_state <= TX_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            uart_tx   <= tx_shift[0];
                            tx_shift  <= {1'b0, tx_shift[7:1]};
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                TX_STOP: begin
                    if (baud_count >= CLKS_PER_BIT - 1) begin
                        baud_count <= 32'd0;
                        if (char_index == REPORT_LENGTH - 1) begin
                            uart_tx  <= 1'b1;
                            tx_state <= TX_IDLE;
                        end else begin
                            char_index <= char_index + 1'b1;
                            tx_state   <= TX_LOAD;
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                default: begin
                    tx_state   <= TX_IDLE;
                    uart_tx    <= 1'b1;
                    baud_count <= 32'd0;
                end
            endcase
        end
    end

endmodule
