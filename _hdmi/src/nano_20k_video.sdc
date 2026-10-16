//Copyright (C)2014-2025 GOWIN Semiconductor Corporation.
//All rights reserved.
//文件标题：时序约束文件
//工具版本： V1.9.11.02 (64-bit) 
//生成时间： 2025-07-16 17:23:11
create_clock -name tmds_clk -period 13.468 -waveform {0 6.734} [get_pins {u_clkdiv/CLKOUT}]
create_clock -name I_clk -period 37.04 -waveform {0 18.52} [get_ports {I_clk}] -add
