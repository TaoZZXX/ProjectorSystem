//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//版权所有。
//文件标题：模块例化模板
//工具版本： V1.9.11.02 (64-bit)
//器件型号： GW2AR-LV18QN88C8/I7
//器件系列： GW2AR-18
//器件版本： C
//生成时间： Wed Jul 16 17:30:23 2025

//请将实例名称和端口连接替换为设计中使用的信号名称。
//--------从此处复制到设计文件--------

	DVI_TX_Top your_instance_name(
		.I_rst_n(I_rst_n), //输入：低有效复位
		.I_serial_clk(I_serial_clk), //输入：高速串行时钟
		.I_rgb_clk(I_rgb_clk), //输入：RGB 像素时钟
		.I_rgb_vs(I_rgb_vs), //输入：场同步信号
		.I_rgb_hs(I_rgb_hs), //输入：行同步信号
		.I_rgb_de(I_rgb_de), //输入：数据有效信号
		.I_rgb_r(I_rgb_r), //输入：8 位红色分量
		.I_rgb_g(I_rgb_g), //输入：8 位绿色分量
		.I_rgb_b(I_rgb_b), //输入：8 位蓝色分量
		.O_tmds_clk_p(O_tmds_clk_p), //输出：TMDS 时钟正端
		.O_tmds_clk_n(O_tmds_clk_n), //输出：TMDS 时钟负端
		.O_tmds_data_p(O_tmds_data_p), //输出：3 路 TMDS 数据正端
		.O_tmds_data_n(O_tmds_data_n) //输出：3 路 TMDS 数据负端
	);

//--------复制内容结束----------------
