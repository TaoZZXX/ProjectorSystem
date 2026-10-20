# 摄像头画面输出到 HDMI

Tang Nano 20K + OV5640，摄像头并口 -> 160×90 RGB565 双缓存 -> 720p60 HDMI。
画面居中放大 6 倍显示为 960×540，四周留黑。打开 `Camera_HDMI.gprj`，顶层为
`camera_hdmi_top`。HDMI 发送、PLL 和串口上报复用同级 `HDMI` 工程。

## 接线（实测确认）

| 信号 | 引脚 | 备注 |
|---|---|---|
| PCLK | 75 | 用户实测确认 |
| VSYNC | 26 | 帧脉冲 |
| HREF | 25 | 行脉冲 |
| D0–D7 | 15、16、17、18、19、20、73、74 | 见 `ov5640摄像头接线.txt` |
| SCL / SDA | 30 / 31 | SCCB，上拉 |
| RST / PWDN | 27 / 28 | PWDN 低有效，代码里恒为 0 |

模块自带 24 MHz 晶振，FPGA 不输出 XCLK；FLASH 引脚（29）不使用。

## 关键发现

1. **HREF 低电平有效**。实测每行 HREF 高电平约 1471 个 PCLK 且期间数据只变化
   1 次，而低电平 640 个 PCLK 正好是 320 像素 × 2 字节——有效像素出现在 HREF
   低电平期间。帧缓存内部统一用 `cam_href_a = ~cam_href`。早期版本按高有效
   采样，全部落在消隐区，读到全 0xFF，表现为整屏白色。
2. **RGB565 字节序正常**：高字节先到（R[4:2]、G[5:3]），低字节（G[2:0]、B[4:3]），
   用传感器内建彩条（0x503D=0x80）逐点比对确认过。
3. 摄像头配置为 320×180 RGB565；FPGA 横纵各抽 1/2 写入 160×90 帧缓存。

## 实现要点

- 帧缓存为两个 160×90×16 bit 的块 RAM，写时钟为 `cam_pclk`、读时钟为
  `pix_clk`，在 HDMI 帧起点切换显示页，不会撕裂。
- 显示：`video_timing_720p60` 产生 1280×720，画面窗口 960×540 居中，缓存像素
  按 6×6 放大；窗口外为黑。
- 状态色：初始化中红、SCCB 失败紫、等待首帧蓝，收到帧后显示摄像头画面。

## 串口诊断

FPGA 69 脚到板载 USB 串口，115200 8N1，每两秒一行：

```text
ID=CAD8BF RB=0140A55B EXP=610108B4 PASS CODE=08
```

- `ID` 后四位是状态位：`ready, error, pclk_seen, vs_seen, href_seen,
  frame_valid, captured, published`。
- `RB`：前三位为每行 PCLK 对（正常 0x140 = 320），中间/最后各一个中间行像素的
  高字节。
- `EXP`：`0x4300` 与 `0x501F` 的回读值、右端像素高字节、每帧行数（正常 0xB4 =
  180）。

## 下载

Gowin Programmer 选 **SRAM Mode / SRAM Program** 加载 `impl/pnr/Camera_HDMI.fs`，
断电即失效。命令行：

```powershell
& '<Gowin>\IDE\bin\gw_sh.exe' build.tcl
& '<Gowin>\Programmer\bin\programmer_cli.exe' -d GW2AR-18C -r 2 --fsFile impl\pnr\Camera_HDMI.fs
```

## 已知限制 / 下一步

160×90 的缓存放大 6 倍后仍是明显色块。受 GW2AR-18 的 46 块 BSRAM（约 103 KB）
限制，「双缓存 + 16 位色」最大只能到 160×90 左右。要做到又大又清晰，需要把帧
缓存搬到板上 8 MB PSRAM：复用 `HDMI/src/sdram_controller_hs` 的控制器，另写一套
摄像头写入 + 显示读出的流式引擎（含行场调度与刷新），工作量较大。
