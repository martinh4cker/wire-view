# 技术架构

## 视频链路

```text
Mac 扩展桌面 / 选定物理屏幕
  → ScreenCaptureKit
  → VideoToolbox H.264 硬件编码
  → Mac 回环 TCP（每台设备独立端口）
  → adb reverse，经 USB
  → Android 回环 TCP 27183
  → MediaCodec 解码到 SurfaceTexture
  → OpenGL ES 外部纹理采样
  → GLSurfaceView / EGL 按显示节奏呈现
```

Mac 用隔离在 `VirtualDisplay.h` 中的私有 `CGVirtualDisplay` 接口创建扩展屏；选择镜像来源时直接采集已有屏幕。`Sender.swift` 负责屏幕生命周期、ScreenCaptureKit、编码、TCP 和性能计时；视频状态集中在专用串行队列，停止时先清理连接和编码器，再释放采集与虚拟显示器。

编码使用实时 H.264、禁止帧重排序并请求硬件低延迟码率控制。Android 收包和输出解码分别在线程中工作，输出到保持视频宽高比的 Surface。静态桌面不重复发送不变画面，空包维持连接。支持 30/60/90/120 fps，60 fps 为默认目标，90/120 为实验档，实际表现取决于主机、设备与画面。

Android 显式传入帧率、实时优先级和预期运行帧率。解码 Surface 由 `VideoSurfaceView.java` 的外部纹理提供，解码线程仍独立排出输出缓冲，GL 线程采样最新纹理并向 RGB 显示 Surface 交换缓冲。动态期间保持 EGL 节奏，连续 500 ms 没有新帧后暂停重复绘制，下一帧唤醒。Activity 暂停时关闭接收连接、暂停 GL 并释放输入纹理，恢复后重建解码 Surface；每个 Receiver 只释放自己持有的 Surface 包装对象。

USB 回环 TCP 保留 `TCP_NODELAY`，并通过本连接的重复文件描述符在每个视频包读取后请求 Linux `TCP_QUICKACK`，减少确认等待造成的小包成批到达。选项不受支持时退回原连接行为，不修改系统网络设置，也不扩大监听地址。该项与 GPU 合成的对照结果见 [性能排查](performance.md)。

## 菜单与设备配置

`AppController.swift` 提供纯菜单栏入口和开始/停止操作。显示中改参数或选设备会串行停止旧会话并建立新会话；主动停止后的设置变更只保存。

`USBDeviceMonitor` 每秒发现已授权的 USB 设备，忽略网络 ADB。`DeviceProfiles.swift` 按设备序列号的 SHA-256 摘要保存配置，不存原始序列号。同型号在菜单中用短摘要区分。每台记录自己的尺寸、画质、帧率、Mac 来源屏幕 UUID 和唯一 Mac 监听端口，当前只允许一个活动视频会话。

`USBReconnect.swift` 只为选定身份的设备建立转发和启动接收端；实际命令使用当前 `transport_id`，重插后身份仍能匹配。Android 端口保持 27183，Mac 端口由本地设备配置分配。旧设备转发不会连入新设备的监听端口；已有冲突转发不会被覆盖。

`DisplayLayout.swift` 按设备保存平板相对邻屏的位置。首次或无法恢复时放到最右端，保留主屏及其他屏幕排列；拔线时保留虚拟屏，退出时移除。

## WTS2 线协议

所有整数均为大端。每个 TCP 连接只承载一条视频流，连接重建时重新发送头部及解码配置。

连接头：

| 字段 | 长度 | 含义 |
| --- | --- | --- |
| magic | 4 字节 | ASCII `WTS2`，即 `0x57545332` |
| width | uint32 | 视频像素宽度 |
| height | uint32 | 视频像素高度 |
| fps | uint32 | 目标帧率 |

Mac 到 Android 的视频包：

| 字段 | 长度 | 含义 |
| --- | --- | --- |
| size | uint32 | H.264 载荷字节数；0 表示保活，后续字段省略 |
| pts | uint64 | Mac 单调时钟的微秒值 |
| flags | uint32 | 1 为关键帧，2 为编解码配置，可按位组合 |
| payload | size 字节 | Annex B H.264，配置包携带 SPS/PPS |

接收端限制单包最大 4 MiB、宽高各 16–4096、头部帧率 1–120；菜单提供 30/60/90/120 fps。协议变更需同时更新两端，当前没有版本协商或兼容旧 magic 的回退。

Android 每收到 10 次解码器渲染回调回传一次该帧 `pts`（uint64），没有额外包头。Mac 用同一时钟计算发送端采集回调到解码器回执的耗时，包含回执返回时间；Android 分别记录收齐视频帧到解码输出、GPU 采样新纹理的节奏。解码回调不等同于 EGL 交换缓冲、系统合成或面板呈现。两端时钟不需同步，也不能用该值代表面板像素亮起或触摸响应延迟。

## 测试与边界

`macos/tests/` 覆盖设置持久化、A/B 配置隔离、转发目标与冲突、重插后的 transport、排列恢复和原生菜单动作。默认测试不依赖设备，`--video` 使用一台真实 USB 平板及模拟的离线 B，验证自动重连、恢复配置和端口隔离。两台实机切换需另做手动验收。

当前未实现触控回传、音频、AOA 和同时向多台设备输出。私有虚拟显示接口、ad-hoc 签名后的录屏授权以及不同平板的解码器是主要兼容性边界。传输安全与本地数据说明见 [SECURITY.md](../SECURITY.md)。
