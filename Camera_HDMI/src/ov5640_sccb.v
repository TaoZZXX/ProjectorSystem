// OV5640 的 SCCB 写接口；从机 7 位地址 0x3c。
// SCL 由 FPGA 推挽驱动；SDA 开漏，只下拉或释放。
module ov5640_sccb (
    input  wire clk,
    input  wire reset_n,
    input  wire start,
    input  wire read_mode,
    input  wire [15:0] reg_addr,
    input  wire [7:0] reg_data,
    output wire scl,
    inout  wire sda,
    output reg  busy,
    output reg  done,
    output reg  nack,
    output reg  [7:0] read_data
);
    localparam [4:0] IDLE=0, START_0=1, START_1=2,
                     BIT_LOW=3, BIT_HIGH=4, ACK_LOW=5, ACK_HIGH=6,
                     ACK_SAMPLE=7, STOP_LOW=8, STOP_HIGH=9,
                     STOP_RELEASE=10,
                     READ_LOW=13, READ_HIGH=14, READ_SAMPLE=15,
                     READ_NACK=16, BIT_FALL=17, ACK_FALL=18,
                     STOP_FALL=19, READ_FALL=20, NACK_HIGH=21;
    reg [4:0] state;
    reg read_request;
    reg read_phase2;
    reg [7:0] divider;
    reg [31:0] shift;
    reg [2:0] bit_index;
    reg [1:0] byte_index;
    reg scl_low, sda_low;
    assign scl = ~scl_low;
    assign sda = sda_low ? 1'b0 : 1'bz;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            divider <= 8'd0;
            shift <= 32'd0;
            bit_index <= 3'd7;
            byte_index <= 2'd0;
            scl_low <= 1'b0;
            sda_low <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            nack <= 1'b0;
            read_request <= 1'b0;
            read_phase2 <= 1'b0;
            read_data <= 8'd0;
        end else begin
            done <= 1'b0;
            if (state == IDLE) begin
                divider <= 8'd0;
                if (start) begin
                    shift <= {8'h78, reg_addr, reg_data};
                    read_request <= read_mode;
                    read_phase2 <= 1'b0;
                    read_data <= 8'd0;
                    bit_index <= 3'd7;
                    byte_index <= 2'd0;
                    nack <= 1'b0;
                    busy <= 1'b1;
                    state <= START_0;
                end
            end else if (divider == 8'd134) begin
                divider <= 8'd0; // 每半周期 5 us，SCL 约 100 kHz
                case (state)
                    START_0: begin
                        scl_low <= 1'b0;
                        sda_low <= 1'b0;
                        state <= START_1;
                    end
                    START_1: begin
                        sda_low <= 1'b1; // SCL 高时 SDA 下降：START
                        state <= BIT_FALL;
                    end
                    BIT_FALL: begin
                        scl_low <= 1'b1;
                        state <= BIT_LOW;
                    end
                    BIT_LOW: begin
                        sda_low <= ~shift[31];
                        state <= BIT_HIGH;
                    end
                    BIT_HIGH: begin
                        scl_low <= 1'b0;
                        shift <= {shift[30:0], 1'b0};
                        if (bit_index == 3'd0) begin
                            bit_index <= 3'd7;
                            state <= ACK_FALL;
                        end else begin
                            bit_index <= bit_index - 1'b1;
                            state <= BIT_FALL;
                        end
                    end
                    ACK_FALL: begin
                        scl_low <= 1'b1;
                        state <= ACK_LOW;
                    end
                    ACK_LOW: begin
                        sda_low <= 1'b0;
                        state <= ACK_HIGH;
                    end
                    ACK_HIGH: begin
                        scl_low <= 1'b0;
                        state <= ACK_SAMPLE;
                    end
                    ACK_SAMPLE: begin
                        if (sda !== 1'b0) nack <= 1'b1;
                        if (byte_index == 2'd3)
                            state <= read_request ? READ_FALL : STOP_FALL;
                        else if (byte_index == 2'd2 && read_request) begin
                            read_phase2 <= 1'b1;
                            state <= STOP_FALL;
                        end
                        else begin
                            byte_index <= byte_index + 1'b1;
                            state <= BIT_FALL;
                        end
                    end
                    READ_FALL: begin
                        scl_low <= 1'b1;
                        state <= READ_LOW;
                    end
                    READ_LOW: begin
                        sda_low <= 1'b0;
                        state <= READ_HIGH;
                    end
                    READ_HIGH: begin
                        scl_low <= 1'b0;
                        state <= READ_SAMPLE;
                    end
                    READ_SAMPLE: begin
                        read_data <= {read_data[6:0], sda};
                        if (bit_index == 3'd0) begin
                            bit_index <= 3'd7;
                            state <= READ_NACK; // 单字节读后主机不应答
                        end else begin
                            bit_index <= bit_index - 1'b1;
                            state <= READ_FALL;
                        end
                    end
                    READ_NACK: begin
                        scl_low <= 1'b1;
                        sda_low <= 1'b0;
                        state <= NACK_HIGH;
                    end
                    NACK_HIGH: begin
                        scl_low <= 1'b0; // 第九个时钟保持 SDA 高：NACK
                        state <= STOP_FALL;
                    end
                    STOP_FALL: begin
                        scl_low <= 1'b1;
                        state <= STOP_LOW;
                    end
                    STOP_LOW: begin
                        sda_low <= 1'b1;
                        state <= STOP_HIGH;
                    end
                    STOP_HIGH: begin
                        scl_low <= 1'b0;
                        state <= STOP_RELEASE;
                    end
                    STOP_RELEASE: begin
                        sda_low <= 1'b0; // SCL 高时 SDA 上升：STOP
                        if (read_request && read_phase2) begin
                            read_phase2 <= 1'b0;
                            shift <= {8'h79, 24'd0};
                            byte_index <= 2'd3;
                            bit_index <= 3'd7;
                            state <= START_0;
                        end else begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= IDLE;
                        end
                    end
                    default: state <= IDLE;
                endcase
            end else divider <= divider + 1'b1;
        end
    end
endmodule
