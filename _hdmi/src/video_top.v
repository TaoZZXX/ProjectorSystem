// ==============0ooo===================================================0ooo===========
// =  Copyright (C) 2014-2020 Gowin Semiconductor Technology Co.,Ltd.
// =                     版权所有。
// ====================================================================================
// 
//  __      __      __
//  \ \    /  \    / /   [文件名       ] video_top.v
//   \ \  / /\ \  / /    [说明         ] 视频演示顶层
//    \ \/ /  \ \/ /     [时间         ] 2020年4月10日 星期五 14:00:30
//     \  /    \  /      [版本         ] 2.0
//      \/      \/
//
// ==============0ooo===================================================0ooo===========
// 代码修订记录：
// ----------------------------------------------------------------------------------
// 版本    | 作者       | 修改日期     | 修改内容：
// ----------------------------------------------------------------------------------
// V1.0    | Caojie     |  4/10/20     | 初始版本 
// ----------------------------------------------------------------------------------
// V2.0    | Caojie     | 10/30/20     | 更新 DVI IP 
// ----------------------------------------------------------------------------------
// ==============0ooo===================================================0ooo===========

module video_top
(
    input             I_clk           , //27 MHz 板载时钟
    input             I_rst           ,
    input             I_key           ,
    output     [4:0]  O_led           ,
    output            running         ,
    output            O_tmds_clk_p    ,
    output            O_tmds_clk_n    ,
    output     [2:0]  O_tmds_data_p   ,//TMDS 正端数据通道：{R、G、B}
    output     [2:0]  O_tmds_data_n   
);

//==================================================
assign      I_rst_n = ~I_rst;

reg  [1:0]  KEY_sync;

reg  [31:0] run_cnt;
wire        running;
wire        I_rst_n;

// 按键切换显示模式
reg [1:0] KEY_sync;
always @(posedge pix_clk or negedge hdmi4_rst_n) begin
    if (!hdmi4_rst_n)    
        KEY_sync <= 2'b00;
    else                 
        KEY_sync <= {KEY_sync[0], I_key};
end


wire KEY_pressed =  KEY_sync[0] & ~KEY_sync[1];

reg [2:0]   mode_reg;

always @(posedge pix_clk or negedge hdmi4_rst_n) begin
    if (!hdmi4_rst_n)      
        mode_reg <= 3'd0;
    else if (KEY_pressed)   
        mode_reg <= mode_reg + 3'd1;
    else                   
        mode_reg <= mode_reg;
end


//--------------------------
wire        tp0_vs_in  ;
wire        tp0_hs_in  ;
wire        tp0_de_in ;
wire [ 7:0] tp0_data_r/*synthesis syn_keep=1*/;
wire [ 7:0] tp0_data_g/*synthesis syn_keep=1*/;
wire [ 7:0] tp0_data_b/*synthesis syn_keep=1*/;

reg         vs_r;
reg  [9:0]  cnt_vs;

//------------------------------------
// HDMI/DVI TMDS 发射端时钟与复位
wire serial_clk;
wire pll_lock;

wire hdmi4_rst_n;

wire pix_clk;

//===================================================
// LED 状态指示：每约 1 秒翻转一次
always @(posedge I_clk or negedge I_rst_n) //使用板载 27 MHz 时钟计数
begin
    if(!I_rst_n)
        run_cnt <= 32'd0;
    else if(run_cnt >= 32'd27_000_000)
        run_cnt <= 32'd0;
    else
        run_cnt <= run_cnt + 1'b1;
end

assign  running = (run_cnt < 32'd14_000_000) ? 1'b1 : 1'b0;

//===========================================================================
// 测试图案发生器与 720p 时序参数
testpattern testpattern_inst
(
    .I_pxl_clk   (pix_clk            ),//像素时钟
    .I_rst_n     (hdmi4_rst_n        ),//低电平有效复位
    .I_mode      (mode_reg           ),//图案选择
    .I_single_r  (8'd0               ),
    .I_single_g  (8'd255             ),
    .I_single_b  (8'd0               ),                  //纯色模式下的蓝色分量    
    .I_h_total   (12'd1650           ),//水平总周期：1280 有效 + 110 前肩 + 40 同步 + 220 后肩
    .I_h_sync    (12'd40             ),//水平同步宽度
    .I_h_bporch  (12'd220            ),//水平后肩宽度
    .I_h_res     (12'd1280           ),//水平有效分辨率
    .I_v_total   (12'd750            ),//垂直总周期：720 有效 + 5 前肩 + 5 同步 + 20 后肩
    .I_v_sync    (12'd5              ),//垂直同步宽度
    .I_v_bporch  (12'd20             ),//垂直后肩宽度
    .I_v_res     (12'd720            ),//垂直有效分辨率
    .I_hs_pol    (1'b1               ),//HSYNC 极性：0 为低有效，1 为高有效
    .I_vs_pol    (1'b1               ),//VSYNC 极性：0 为低有效，1 为高有效
    .O_de        (tp0_de_in          ),   
    .O_hs        (tp0_hs_in          ),
    .O_vs        (tp0_vs_in          ),
    .O_data_r    (tp0_data_r         ),   
    .O_data_g    (tp0_data_g         ),
    .O_data_b    (tp0_data_b         )
);

always@(posedge pix_clk)
begin
    vs_r<=tp0_vs_in;
end

always@(posedge pix_clk or negedge hdmi4_rst_n)
begin
    if(!hdmi4_rst_n)
        cnt_vs<=0;
    else if(vs_r && !tp0_vs_in) //检测 VSYNC 下降沿并累计帧数
        cnt_vs<=cnt_vs+1'b1;
end 

//==============================================================================
// TMDS 发送链路：PLL 产生高速时钟，再分频得到像素时钟
TMDS_rPLL u_tmds_rpll
(.clkin     (I_clk     )     //输入时钟
,.clkout    (serial_clk)     //高速串行时钟输出
,.lock      (pll_lock  )     //PLL 锁定指示
);

assign hdmi4_rst_n = I_rst_n & pll_lock;

CLKDIV u_clkdiv
(.RESETN(hdmi4_rst_n)
,.HCLKIN(serial_clk) //5 倍像素时钟
,.CLKOUT(pix_clk)    //像素时钟
,.CALIB (1'b1)
);
defparam u_clkdiv.DIV_MODE="5";
defparam u_clkdiv.GSREN="false";

DVI_TX_Top DVI_TX_Top_inst
(
    .I_rst_n       (hdmi4_rst_n   ),  //异步复位，低电平有效
    .I_serial_clk  (serial_clk    ),
    .I_rgb_clk     (pix_clk       ),  //像素时钟
    .I_rgb_vs      (tp0_vs_in     ), 
    .I_rgb_hs      (tp0_hs_in     ),    
    .I_rgb_de      (tp0_de_in     ), 
    .I_rgb_r       (  tp0_data_r ),  //红色像素分量
    .I_rgb_g       (  tp0_data_g  ),  
    .I_rgb_b       (  tp0_data_b  ),  
    .O_tmds_clk_p  (O_tmds_clk_p  ),
    .O_tmds_clk_n  (O_tmds_clk_n  ),
    .O_tmds_data_p (O_tmds_data_p ),  //TMDS 正端数据通道：{R、G、B}
    .O_tmds_data_n (O_tmds_data_n )
);

key_led_ctrl key_led_ctrl_inst
(
    .I_rst_n       (hdmi4_rst_n   ),
    .I_clk         (pix_clk       ), 
    .I_key         (I_key         ),
    .O_led         (O_led         )
);

endmodule