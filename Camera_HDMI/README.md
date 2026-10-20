# 摄像头画面输出到 HDMI

Tang Nano 20K + 摄像头，当前已在板上验证画面正常，用户确认比原版本清楚。
工程文件：`Camera_HDMI.gprj`，顶层：`camera_hdmi_top`。

## 当前分辨率

OV5640 输出 VGA 640×480 RGB565。FPGA 在垂直方向舍弃顶部和底部各 60 行，
保留居中的 640×360；通过 SDRAM 双帧缓存和双行缓存送到 HDMI，横纵各放大 2 倍，
铺满 1280×720、60 Hz 的有效显示区。显示细节为 640×360。

## 数据通路

1. `ov5640_init.v`：SCCB 配置摄像头输出 VGA 640×480 RGB565，关闭内建测试彩条。
2. `camera_capture.v`：按实测低有效 HREF 采样，拼接 RGB565，并裁取中间 360 行。
3. `sdram_framebuffer.v`：两个相邻像素合成一个 32 位字，经异步 FIFO 写入 SDRAM。
4. SDRAM 使用两帧，帧页基址分别为 0、131072，地址单位为 32 位字；每帧使用 115200 个字。
5. 显示端只在 HDMI 场消隐切换完整帧，提前读取下一源行到另一条行缓存。
6. `camera_hdmi_top.v`：每个源像素显示 2×2 次，RGB565 展开为 RGB888，再送到 DVI 编码器。

SDRAM 时钟为 108 MHz，复用已经验证过的 0° 时钟相位配置。
当前布局布线报告使用 5/46 块 BSRAM，完整帧保存在芯片配套 SDRAM 中。
历史实验模块 `camera_framebuffer.v`、`cam_fb320.v`、`sdram_fb.v`、`sdram_probe.v`
保留在目录中，但没有加入当前工程，不参与综合。

## 接线与已确认特性

| 信号 | FPGA 引脚 |
|---|---|
| PCLK | 75 |
| VSYNC | 26 |
| HREF | 25 |
| D0–D7 | 15、16、17、18、19、20、73、74 |
| SCL / SDA | 30 / 31 |
| RST / PWDN | 27 / 28 |
| UART TX | 69 |

摄像头模块自带 24 MHz 晶振，不需要 FPGA 输出 XCLK。
HREF 实测低有效，不能改回按高电平采样；RGB565 高字节先到。
PWDN 高电平有效，代码恒置 0，保持摄像头工作。
FLASH 引脚不声明、不驱动，闪光灯线保持悬空，不开启闪光灯。
SDRAM 为配套的内部连接，无需另接杜邦线。

## 串口状态

COM4，115200、8N1，每两秒一行，例如：

```text
ID=564002 RB=00C7E670 EXP=00B40140 PASS CODE=01
```

- `ID`：高 16 位为传感器 ID，最后两位的 bit1 表示配置完成，bit0 表示配置错误。
- `RB`：高 16 位为已保存完整帧的计数，低 16 位为已读取行的计数，均按 16 位回卷。
- `EXP`：高 16 位是摄像头检测到的有效行数，正常 0x01E0=480；低 16 位是每行像素数，正常 0x0280=640。
- `PASS` / `CODE=01`：显示侧已接收完整帧。该标志代表帧交接完成，最终画质仍需观察屏幕。

帧缓存仅写入裁切后的 360 行；串口 `EXP` 显示传感器原始 VGA 行列计数。
摄像头采集速度和双帧交接决定画面更新速度，HDMI 输出时序保持 60 Hz。

## 编译与下载

在本目录执行：

```powershell
& 'G:\soft\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe' build.tcl
```

使用 Gowin Programmer 的 **SRAM Mode / SRAM Program** 加载 `impl/pnr/Camera_HDMI.fs`。
当前已经用 SRAM 模式下载并验证，断电后这次临时配置会消失。

## 恢复原版本

优化前的代码、工程和可直接下载的 `working.fs` 保存在同级目录：
`../Camera_HDMI_backup_20261020_205326/`。
需要临时恢复旧画面时，可以直接以 SRAM 模式下载该目录的 `working.fs`。
