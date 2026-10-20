// OV5640 上电配置：DVP、320x240、RGB565。初始化寄存器序列改编自
// STMicroelectronics stm32-ov5640/ov5640.c (BSD-3-Clause)。
// https://github.com/STMicroelectronics/stm32-ov5640
module ov5640_init (
    input  wire clk_27m,
    input  wire reset_n,
    inout  wire cam_sda,
    output wire cam_scl,
    output reg  cam_rst_n,
    output wire cam_pwdn,
    output reg  ready,
    output reg  error,
    output reg  [15:0] sensor_id,
    output reg  [7:0] sensor_ctrl,
    output reg  [7:0] sensor_pad
);
    localparam [8:0] REG_COUNT = 9'd264;
    localparam [3:0] HOLD_RESET = 4'd0, WAIT_BOOT = 4'd1,
                     ISSUE = 4'd2, WAIT_WRITE = 4'd3,
                     WAIT_SOFT_RESET = 4'd4, COMPLETE = 4'd5,
                     READ_ID_H = 4'd6, WAIT_ID_H = 4'd7,
                     READ_ID_L = 4'd8, WAIT_ID_L = 4'd9,
                     DELAY_READ_L = 4'd10,
                     READ_CTRL = 4'd11, WAIT_CTRL = 4'd12,
                     READ_PAD = 4'd13, WAIT_PAD = 4'd14;
    reg [3:0] state;
    reg [19:0] delay_count;
    reg [8:0] index;
    reg start_write;
    wire write_busy;
    wire write_done;
    wire write_nack;
    wire [7:0] read_data;
    wire read_mode = state == READ_ID_H || state == WAIT_ID_H ||
                     state == READ_ID_L || state == WAIT_ID_L ||
                     state == READ_CTRL || state == WAIT_CTRL ||
                     state == READ_PAD || state == WAIT_PAD;
    wire [15:0] operation_addr =
        (state == READ_ID_H || state == WAIT_ID_H) ? 16'h300a :
        (state == READ_ID_L || state == WAIT_ID_L) ? 16'h300b :
        (state == READ_CTRL || state == WAIT_CTRL) ? 16'h4300 :
        (state == READ_PAD || state == WAIT_PAD) ? 16'h501f :
        setting[23:8];
    reg [23:0] setting;
    assign cam_pwdn = 1'b0; // PWDN 高电平有效；始终保持工作。
    always @(*) begin
        case (index)
            9'd0: setting = 24'h310311;
            9'd1: setting = 24'h300882;
            9'd2: setting = 24'h310303;
            9'd3: setting = 24'h363036;
            9'd4: setting = 24'h36310e;
            9'd5: setting = 24'h3632e2;
            9'd6: setting = 24'h363312;
            9'd7: setting = 24'h3621e0;
            9'd8: setting = 24'h3704a0;
            9'd9: setting = 24'h37035a;
            9'd10: setting = 24'h371578;
            9'd11: setting = 24'h371701;
            9'd12: setting = 24'h370b60;
            9'd13: setting = 24'h37051a;
            9'd14: setting = 24'h390502;
            9'd15: setting = 24'h390610;
            9'd16: setting = 24'h39010a;
            9'd17: setting = 24'h373112;
            9'd18: setting = 24'h360008;
            9'd19: setting = 24'h360133;
            9'd20: setting = 24'h302d60;
            9'd21: setting = 24'h362052;
            9'd22: setting = 24'h371b20;
            9'd23: setting = 24'h471c50;
            9'd24: setting = 24'h3a1343;
            9'd25: setting = 24'h3a1800;
            9'd26: setting = 24'h3a19f8;
            9'd27: setting = 24'h363513;
            9'd28: setting = 24'h363603;
            9'd29: setting = 24'h363440;
            9'd30: setting = 24'h362201;
            9'd31: setting = 24'h3c0134;
            9'd32: setting = 24'h3c0428;
            9'd33: setting = 24'h3c0598;
            9'd34: setting = 24'h3c0600;
            9'd35: setting = 24'h3c0700;
            9'd36: setting = 24'h3c0801;
            9'd37: setting = 24'h3c092c;
            9'd38: setting = 24'h3c0a9c;
            9'd39: setting = 24'h3c0b40;
            9'd40: setting = 24'h382006;
            9'd41: setting = 24'h382100;
            9'd42: setting = 24'h381431;
            9'd43: setting = 24'h381531;
            9'd44: setting = 24'h380000;
            9'd45: setting = 24'h380100;
            9'd46: setting = 24'h380200;
            9'd47: setting = 24'h380304;
            9'd48: setting = 24'h38040a;
            9'd49: setting = 24'h38053f;
            9'd50: setting = 24'h380607;
            9'd51: setting = 24'h38079b;
            9'd52: setting = 24'h380803;
            9'd53: setting = 24'h380920;
            9'd54: setting = 24'h380a02;
            9'd55: setting = 24'h380b58;
            9'd56: setting = 24'h380c07;
            9'd57: setting = 24'h380d90;
            9'd58: setting = 24'h380e04;
            9'd59: setting = 24'h380f40;
            9'd60: setting = 24'h381000;
            9'd61: setting = 24'h381110;
            9'd62: setting = 24'h381200;
            9'd63: setting = 24'h381306;
            9'd64: setting = 24'h361800;
            9'd65: setting = 24'h361229;
            9'd66: setting = 24'h370864;
            9'd67: setting = 24'h370952;
            9'd68: setting = 24'h370c03;
            9'd69: setting = 24'h3a0203;
            9'd70: setting = 24'h3a03d8;
            9'd71: setting = 24'h3a0801;
            9'd72: setting = 24'h3a0927;
            9'd73: setting = 24'h3a0a00;
            9'd74: setting = 24'h3a0bf6;
            9'd75: setting = 24'h3a0e03;
            9'd76: setting = 24'h3a0d04;
            9'd77: setting = 24'h3a1403;
            9'd78: setting = 24'h3a15d8;
            9'd79: setting = 24'h400102;
            9'd80: setting = 24'h400402;
            9'd81: setting = 24'h300000;
            9'd82: setting = 24'h30021c;
            9'd83: setting = 24'h3004ff;
            9'd84: setting = 24'h3006c3;
            9'd85: setting = 24'h300e58;
            9'd86: setting = 24'h302e00;
            9'd87: setting = 24'h474022;
            9'd88: setting = 24'h430061;
            9'd89: setting = 24'h501f01;
            9'd90: setting = 24'h471303;
            9'd91: setting = 24'h440704;
            9'd92: setting = 24'h440e00;
            9'd93: setting = 24'h460b35;
            9'd94: setting = 24'h460c23;
            9'd95: setting = 24'h483722;
            9'd96: setting = 24'h382402;
            9'd97: setting = 24'h5000a7;
            9'd98: setting = 24'h5001a3;
            9'd99: setting = 24'h5180ff;
            9'd100: setting = 24'h5181f2;
            9'd101: setting = 24'h518200;
            9'd102: setting = 24'h518314;
            9'd103: setting = 24'h518425;
            9'd104: setting = 24'h518524;
            9'd105: setting = 24'h518609;
            9'd106: setting = 24'h518709;
            9'd107: setting = 24'h518809;
            9'd108: setting = 24'h518975;
            9'd109: setting = 24'h518a54;
            9'd110: setting = 24'h518be0;
            9'd111: setting = 24'h518cb2;
            9'd112: setting = 24'h518d42;
            9'd113: setting = 24'h518e3d;
            9'd114: setting = 24'h518f56;
            9'd115: setting = 24'h519046;
            9'd116: setting = 24'h5191f8;
            9'd117: setting = 24'h519204;
            9'd118: setting = 24'h519370;
            9'd119: setting = 24'h5194f0;
            9'd120: setting = 24'h5195f0;
            9'd121: setting = 24'h519603;
            9'd122: setting = 24'h519701;
            9'd123: setting = 24'h519804;
            9'd124: setting = 24'h519912;
            9'd125: setting = 24'h519a04;
            9'd126: setting = 24'h519b00;
            9'd127: setting = 24'h519c06;
            9'd128: setting = 24'h519d82;
            9'd129: setting = 24'h519e38;
            9'd130: setting = 24'h53811e;
            9'd131: setting = 24'h53825b;
            9'd132: setting = 24'h538308;
            9'd133: setting = 24'h53840a;
            9'd134: setting = 24'h53857e;
            9'd135: setting = 24'h538688;
            9'd136: setting = 24'h53877c;
            9'd137: setting = 24'h53886c;
            9'd138: setting = 24'h538910;
            9'd139: setting = 24'h538a01;
            9'd140: setting = 24'h538b98;
            9'd141: setting = 24'h530008;
            9'd142: setting = 24'h530130;
            9'd143: setting = 24'h530210;
            9'd144: setting = 24'h530300;
            9'd145: setting = 24'h530408;
            9'd146: setting = 24'h530530;
            9'd147: setting = 24'h530608;
            9'd148: setting = 24'h530716;
            9'd149: setting = 24'h530808;
            9'd150: setting = 24'h530930;
            9'd151: setting = 24'h530a04;
            9'd152: setting = 24'h530b06;
            9'd153: setting = 24'h548001;
            9'd154: setting = 24'h548108;
            9'd155: setting = 24'h548214;
            9'd156: setting = 24'h548328;
            9'd157: setting = 24'h548451;
            9'd158: setting = 24'h548565;
            9'd159: setting = 24'h548671;
            9'd160: setting = 24'h54877d;
            9'd161: setting = 24'h548887;
            9'd162: setting = 24'h548991;
            9'd163: setting = 24'h548a9a;
            9'd164: setting = 24'h548baa;
            9'd165: setting = 24'h548cb8;
            9'd166: setting = 24'h548dcd;
            9'd167: setting = 24'h548edd;
            9'd168: setting = 24'h548fea;
            9'd169: setting = 24'h54901d;
            9'd170: setting = 24'h558002;
            9'd171: setting = 24'h558340;
            9'd172: setting = 24'h558410;
            9'd173: setting = 24'h558910;
            9'd174: setting = 24'h558a00;
            9'd175: setting = 24'h558bf8;
            9'd176: setting = 24'h580023;
            9'd177: setting = 24'h580114;
            9'd178: setting = 24'h58020f;
            9'd179: setting = 24'h58030f;
            9'd180: setting = 24'h580412;
            9'd181: setting = 24'h580526;
            9'd182: setting = 24'h58060c;
            9'd183: setting = 24'h580708;
            9'd184: setting = 24'h580805;
            9'd185: setting = 24'h580905;
            9'd186: setting = 24'h580a08;
            9'd187: setting = 24'h580b0d;
            9'd188: setting = 24'h580c08;
            9'd189: setting = 24'h580d03;
            9'd190: setting = 24'h580e00;
            9'd191: setting = 24'h580f00;
            9'd192: setting = 24'h581003;
            9'd193: setting = 24'h581109;
            9'd194: setting = 24'h581207;
            9'd195: setting = 24'h581303;
            9'd196: setting = 24'h581400;
            9'd197: setting = 24'h581501;
            9'd198: setting = 24'h581603;
            9'd199: setting = 24'h581708;
            9'd200: setting = 24'h58180d;
            9'd201: setting = 24'h581908;
            9'd202: setting = 24'h581a05;
            9'd203: setting = 24'h581b06;
            9'd204: setting = 24'h581c08;
            9'd205: setting = 24'h581d0e;
            9'd206: setting = 24'h581e29;
            9'd207: setting = 24'h581f17;
            9'd208: setting = 24'h582011;
            9'd209: setting = 24'h582111;
            9'd210: setting = 24'h582215;
            9'd211: setting = 24'h582328;
            9'd212: setting = 24'h582446;
            9'd213: setting = 24'h582526;
            9'd214: setting = 24'h582608;
            9'd215: setting = 24'h582726;
            9'd216: setting = 24'h582864;
            9'd217: setting = 24'h582926;
            9'd218: setting = 24'h582a24;
            9'd219: setting = 24'h582b22;
            9'd220: setting = 24'h582c24;
            9'd221: setting = 24'h582d24;
            9'd222: setting = 24'h582e06;
            9'd223: setting = 24'h582f22;
            9'd224: setting = 24'h583040;
            9'd225: setting = 24'h583142;
            9'd226: setting = 24'h583224;
            9'd227: setting = 24'h583326;
            9'd228: setting = 24'h583424;
            9'd229: setting = 24'h583522;
            9'd230: setting = 24'h583622;
            9'd231: setting = 24'h583726;
            9'd232: setting = 24'h583844;
            9'd233: setting = 24'h583924;
            9'd234: setting = 24'h583a26;
            9'd235: setting = 24'h583b28;
            9'd236: setting = 24'h583c42;
            9'd237: setting = 24'h583dce;
            9'd238: setting = 24'h502500;
            9'd239: setting = 24'h3a0f30;
            9'd240: setting = 24'h3a1028;
            9'd241: setting = 24'h3a1b30;
            9'd242: setting = 24'h3a1e26;
            9'd243: setting = 24'h3a1160;
            9'd244: setting = 24'h3a1f14;
            9'd245: setting = 24'h300802;
            9'd246: setting = 24'h3017ff;
            9'd247: setting = 24'h3018f3;
            9'd248: setting = 24'h302e00;
            9'd249: setting = 24'h471c50;
            9'd250: setting = 24'h300e58;
            9'd251: setting = 24'h303418;
            9'd252: setting = 24'h303541;
            9'd253: setting = 24'h303660;
            9'd254: setting = 24'h303713;
            9'd255: setting = 24'h310801;
            9'd256: setting = 24'h380801;
            9'd257: setting = 24'h380940;
            9'd258: setting = 24'h380a00;
            9'd259: setting = 24'h380bb4;
            9'd260: setting = 24'h430061;
            9'd261: setting = 24'h501f01;
            9'd262: setting = 24'h474022;
            9'd263: setting = 24'h503d00;
            default: setting = 24'h000000;
        endcase
    end
    ov5640_sccb u_sccb (
        .clk(clk_27m), .reset_n(reset_n), .start(start_write),
        .read_mode(read_mode),
        .reg_addr(operation_addr), .reg_data(setting[7:0]),
        .scl(cam_scl), .sda(cam_sda),
        .busy(write_busy), .done(write_done), .nack(write_nack),
        .read_data(read_data)
    );
    always @(posedge clk_27m or negedge reset_n) begin
        if (!reset_n) begin
            state <= HOLD_RESET;
            delay_count <= 20'd0;
            index <= 9'd0;
            start_write <= 1'b0;
            cam_rst_n <= 1'b0;
            ready <= 1'b0;
            error <= 1'b0;
            sensor_id <= 16'd0;
            sensor_ctrl <= 8'd0;
            sensor_pad <= 8'd0;
        end else begin
            start_write <= 1'b0;
            case (state)
                HOLD_RESET: begin
                    cam_rst_n <= 1'b0;
                    if (delay_count == 20'd269999) begin // 10 ms
                        delay_count <= 20'd0;
                        cam_rst_n <= 1'b1;
                        state <= WAIT_BOOT;
                    end else delay_count <= delay_count + 1'b1;
                end
                WAIT_BOOT: begin
                    if (delay_count == 20'd539999) begin // 20 ms
                        delay_count <= 20'd0;
                        state <= ISSUE;
                    end else delay_count <= delay_count + 1'b1;
                end
                ISSUE: begin
                    if (!write_busy) begin
                        start_write <= 1'b1;
                        state <= WAIT_WRITE;
                    end
                end
                WAIT_WRITE: if (write_done) begin
                    if (write_nack) error <= 1'b1;
                    if (index == 9'd1) begin // 0x3008 软件复位后等 10 ms
                        index <= index + 1'b1;
                        delay_count <= 20'd0;
                        state <= WAIT_SOFT_RESET;
                    end else if (index == REG_COUNT - 1'b1) begin
                        state <= READ_ID_H;
                    end else begin
                        index <= index + 1'b1;
                        state <= ISSUE;
                    end
                end
                WAIT_SOFT_RESET: begin
                    if (delay_count == 20'd269999) begin
                        delay_count <= 20'd0;
                        state <= ISSUE;
                    end else delay_count <= delay_count + 1'b1;
                end
                READ_ID_H: begin
                    if (!write_busy) begin
                        start_write <= 1'b1;
                        state <= WAIT_ID_H;
                    end
                end
                WAIT_ID_H: if (write_done) begin
                    if (write_nack) error <= 1'b1;
                    sensor_id[15:8] <= read_data;
                    delay_count <= 20'd0;
                    state <= DELAY_READ_L;
                end
                DELAY_READ_L: begin
                    if (delay_count == 20'd134999) begin
                        delay_count <= 20'd0;
                        state <= READ_ID_L;
                    end else delay_count <= delay_count + 1'b1;
                end
                READ_ID_L: begin
                    if (!write_busy) begin
                        start_write <= 1'b1;
                        state <= WAIT_ID_L;
                    end
                end
                WAIT_ID_L: if (write_done) begin
                    if (write_nack || {sensor_id[15:8], read_data} != 16'h5640)
                        error <= 1'b1;
                    sensor_id[7:0] <= read_data;
                    state <= READ_CTRL;
                end
                READ_CTRL: begin
                    if (!write_busy) begin
                        start_write <= 1'b1;
                        state <= WAIT_CTRL;
                    end
                end
                WAIT_CTRL: if (write_done) begin
                    if (write_nack) error <= 1'b1;
                    sensor_ctrl <= read_data;
                    state <= READ_PAD;
                end
                READ_PAD: begin
                    if (!write_busy) begin
                        start_write <= 1'b1;
                        state <= WAIT_PAD;
                    end
                end
                WAIT_PAD: if (write_done) begin
                    if (write_nack) error <= 1'b1;
                    sensor_pad <= read_data;
                    state <= COMPLETE;
                end
                COMPLETE: ready <= 1'b1;
                default: state <= HOLD_RESET;
            endcase
        end
    end
endmodule
