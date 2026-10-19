//版权所有 (C) 2014-2025 Gowin Semiconductor Corporation。
//保留所有权利。
//文件说明：模块例化模板
//工具版本：V1.9.11.03 Education
//器件型号：GW2AR-LV18QN88C8/I7
//器件系列：GW2AR-18
//器件版本：C
//生成时间：2026 年 10 月 19 日 星期一 12:28:15

//请将实例名称和端口连接修改为设计中的信号名称
//--------从此处复制到设计文件中--------

	SPI_Flash_Interface_Lite_Top your_instance_name(
		.I_hclk(I_hclk), // 输入：AHB 总线时钟
		.I_hresetn(I_hresetn), // 输入：AHB 总线低电平有效复位
		.I_haddr_reg(I_haddr_reg), // 输入：[31:0] AHB 寄存器地址
		.O_hrdata_reg(O_hrdata_reg), // 输出：[31:0] AHB 寄存器读数据
		.I_hreadyin_reg(I_hreadyin_reg), // 输入：AHB 主设备就绪信号
		.O_hreadyout_reg(O_hreadyout_reg), // 输出：AHB 从设备就绪信号
		.O_hresp_reg(O_hresp_reg), // 输出：[1:0] AHB 传输响应
		.I_hsel_reg(I_hsel_reg), // 输入：AHB 从设备选择信号
		.I_htrans_reg(I_htrans_reg), // 输入：[1:0] AHB 传输类型
		.I_hwdata_reg(I_hwdata_reg), // 输入：[31:0] AHB 写数据
		.I_hwrite_reg(I_hwrite_reg), // 输入：AHB 读写控制，1 为写，0 为读
		.O_flash_ck(O_flash_ck), // 输出：SPI Flash 时钟
		.O_flash_cs_n(O_flash_cs_n), // 输出：SPI Flash 片选，低电平有效
		.IO_flash_hold_n(IO_flash_hold_n), // 双向：SPI Flash 保持信号
		.IO_flash_wp_n(IO_flash_wp_n), // 双向：SPI Flash 写保护信号
		.IO_flash_do(IO_flash_do), // 双向：SPI Flash DO/MISO 数据线
		.IO_flash_di(IO_flash_di) // 双向：SPI Flash DI/MOSI 数据线
	);

//--------复制内容到此结束--------
