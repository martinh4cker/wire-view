# WireView

用 USB 数据线把普通 Android 平板变成电脑的扩展屏。项目名不绑定宿主平台，重点是低延迟、有线传输和简单设置。

**状态：开发原型，版本 0.1.0，MIT 开源。** 已在一台 Apple 芯片 Mac 和 Android 13 平板验证扩展桌面；依赖 macOS 私有虚拟显示接口，尚未正式发行或公证。更多设备兼容性仍需验证。

Mac 菜单栏和 Android 接收端支持简体中文与英文，并分别跟随 Mac 和 Android 的系统语言；其他语言回退为英文。

**平台路线：** 当前实现是 Mac → Android；Windows → Android 是后续适配方向，尚未实现。Mac 和 Windows 的虚拟显示、桌面采集及编码需要分别适配，Android 接收端与传输协议可作为共用基础。

- 独立扩展桌面，或镜像选定的 Mac 屏幕；保留原主屏与现有排列。
- 纯菜单栏勾选尺寸、画质、帧率与安卓设备，显示中修改自动重连。
- 每台安卓设备分别记住配置和排列；USB 拔插后自动恢复到所选设备。
- 目标 60 fps，采用 H.264 硬件编解码；全程经 USB 和回环地址，无遥测或外部服务。

## 环境要求

| 部分 | 要求 |
| --- | --- |
| Mac | Apple 芯片，macOS 15 或以上，提供 macOS 15 SDK 的 Xcode 命令行工具 |
| Android | Android 8 / API 26 或以上，H.264 解码器，已开启并授权 USB 调试 |
| Android 构建 | JDK 17、SDK Platform 35、Build-Tools 35.0.0 |
| USB 工具 | Android Platform-Tools，Mac 能运行 `adb` |

Android SDK 通过 `ANDROID_SDK_ROOT` 或 `ANDROID_HOME` 指定，未设置时尝试标准用户 SDK 目录。构建脚本不下载依赖，也不需要 Gradle 或第三方应用库。首次实测为 Android 13，更早版本仅为代码声明的兼容范围。

如果 Mac 同时安装了多个 JDK，可在构建前切到已安装的 JDK 17：

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export PATH="$JAVA_HOME/bin:$PATH"
```

SDK 安装在其他目录时，先将 `ANDROID_SDK_ROOT` 指向自己的 SDK 根目录；该目录中需包含 `platforms/android-35/android.jar` 和 `build-tools/35.0.0/`。不要将本机 SDK 路径写进源码或提交到仓库。

## 快速开始

1. 在项目根目录构建两端：

   ```sh
   make release
   ```

   `release/` 会生成 `WireView.app` 和 `wire-view.apk`。也可用 `make build` 仅构建到 `.build/`。Mac App 使用 ad-hoc 签名，Android APK 使用本地调试签名；这些是本机安装包，不是商店发行签名。
2. 用数据线连接平板并运行 `adb devices -l`，确认只有一台 USB 测试设备且状态为 `device`。安装和启动接收端：

   ```sh
   adb -d install -r .build/android/wire-view.apk
   adb -d shell am start -n dev.wireview.receiver/.MainActivity
   ```

3. 打开 `release/WireView.app`，点菜单栏双屏图标，再点「开始显示」。程序默认只显示菜单栏图标，不弹窗口、不自动录屏。新的 Mac Bundle ID 需要重新授予录屏权限。首次平板排在最右端，可在「更多 → 屏幕排列…」拖动 `WireView`，下次恢复相对位置。

多台设备安装时，用 `adb devices -l` 查当前 USB `transport_id`，再用 `adb -t` 指定安装目标；每台都需安装接收端。使用时在「安卓设备」菜单选择输出到哪一台。

调试签名仅保存在被 Git 忽略的 `.build/`。删除该目录会丢失原签名，重新生成的 APK 可能无法覆盖已安装版本；可保留本地签名，或在测试设备卸载旧接收端后重新安装。不要把签名材料加入仓库。

## 菜单与性能

菜单里的「尺寸、画质、帧率、屏幕」用勾选表示当前选项，点选后立即保存并生效；显示中会短暂重连。屏幕默认「扩展桌面」，也可选镜像内屏或其他已连接显示器，保留原有主屏和排列。

帧率可选 30、60、90、120；默认与三个预设仍为 60。90/120 是高帧率实验选项，会同时作为虚拟显示模式、编码器和接收端的目标，并按设备保存。设置值不代表实测呈现帧率；能否达到取决于采集、编码、传输、解码及平板当前刷新模式。90 fps 在仅提供 60/120 Hz 模式的面板上也不能保证均匀显示。

「安卓设备」选择视频显示到哪一台。每台分别记住尺寸、画质、帧率、Mac 屏幕来源和排列位置；例如 A 用 1600×1000/省流，B 用 1920×1200/清晰，切回 A 会恢复它自己的设置。显示中切换设备或参数都会自动重连，无须再次点开始；主动停止后修改设置只保存。一次只向选中的一台输出，未连接的已知设备也可提前配置。首次仅有一台 USB 设备时自动选中并继承旧设置；多台时由用户选择，新设备默认均衡。同型号用短标识区分，原始序列号不落盘。

| 预设 | 尺寸 | 帧率 | 压缩码率 |
| --- | --- | --- | --- |
| 流畅优先 | 1280×800 | 60 fps | 4 Mbps |
| 均衡（默认） | 1920×1200 | 60 fps | 10 Mbps |
| 清晰优先 | 2560×1600 | 60 fps | 20 Mbps |

想降低解码负载优先减小尺寸，想减少数据量可降低画质。降低码率不保证降低延迟；低分辨率也会使小字变模糊。早期三档测试的解码渲染回调均接近 60 fps，回执延迟中位数分别约 28、43、50 ms；这些回调数据不能代表实际呈现帧率。

后续排查发现 USB 回环 TCP 的确认等待会造成约 40 ms 的抖动，且当前平板的解码视频直出路径实际呈现约 30 fps。接收端现使用每连接即时确认及 `MediaCodec → SurfaceTexture → OpenGL ES → GLSurfaceView`，由 GPU 按屏幕节奏合成。1280×800/4 Mbps/60 fps 测试图的系统呈现统计约 60 fps、新纹理更新约 58–60 fps，前后台恢复后也能回到约 60 fps；尚未据此验证所有桌面场景或设备。[排查与验证记录](docs/performance.md)

如果参照屏幕没有连接，或原位置已经被别的屏幕占用，平板暂时放在最右端，记忆仍保留。排列记录只存在 Mac 本地。

用 `adb -d logcat -s WireView:I` 查看 `Cadence received`、`decoded`、`GPU-latched` 的帧率与间隔；`Codec callbacks` 是解码器回调计数，不能直接代表实际呈现。实际呈现需另看 SurfaceFlinger 的视频层统计。Mac 的回执计时来自解码器回调并包含回执返回时间，不等同于 GPU 合成、面板亮起或触摸响应。只想验证有线视频时，可退出桌面模式后用 `open '.build/WireView.app' --args --test-pattern`；需要 30 帧对比时加 `--30fps`。

Mac App 运行期间每秒检查一次 USB 平板，自动创建并恢复所选设备的 `adb reverse`。拔线后直接插回，接收 App 将自动重新连接；如果重新出现 USB 调试授权弹窗，需要在平板上允许。记住的设备身份是仅存在 Mac 本地的 SHA-256 摘要，不会因插入另一台设备而切换。每台使用独立的 Mac 监听端口，旧目标的连接不会进入新目标的会话；设备端仍使用 27183。每台都需事先安装接收 App；不使用 Wi-Fi ADB，不覆盖已有的冲突转发。

当前拔线后仍保留 Mac 虚拟显示器，重新连接会沿用位置；自动移除并重建屏幕尚未实现。退出 Mac App 会移除虚拟显示器。

结束显示时点菜单里的「停止显示」；「退出」会退出菜单栏程序。需要撤销转发时，可在退出后运行 `adb -d reverse --remove tcp:27183`。

## 已知限制

默认使用 1920×1200、60 Hz，可实验性设置最高 120 fps。静态内容不重复发送未改变的帧。虚拟显示器依赖 macOS 私有 `CGVirtualDisplay` 接口，系统更新后可能需要适配。重新编译和 ad-hoc 签名可能要求重新授予录屏权限。

当前未实现触控回传、音频、AOA 或同时向多台设备输出。不同设备的解码能力与低延迟模式支持不同；单台测试结果不能代表所有安卓平板。

## 开发与测试

开发验证：`bash macos/test.sh` 运行配置、设备选择、转发、排列和原生菜单测试。先退出运行中的 Mac App，连接一台已授权且装好接收端的 USB 平板，再用 `bash macos/test.sh --video` 验证真实视频自动重连；仅生成测试图，不采集桌面。A/B 配置隔离和目标选择包含模拟 ADB 测试；同时连接两台真实平板尚未验收。

```sh
make test
# 实机测试，执行前退出 Mac App：
make test-video
# 可选：同样只用测试图，额外验证 90/120 帧目标（不保证实际满帧）：
bash macos/test.sh --video --high-fps
```

```text
macos/        菜单栏、设备配置、虚拟屏、采集、编码及测试
android/      原生 Android 接收端和 APK 构建脚本
docs/         需求、验收记录和技术架构
.github/      Issue 与 PR 模板
Makefile      本地构建与测试入口
```

详细说明：[技术架构与协议](docs/architecture.md) · [需求与验收](docs/requirements.md) · [贡献指南](CONTRIBUTING.md) · [安全与隐私](SECURITY.md)。

## 许可证

项目代码采用 [MIT License](LICENSE)。仓库不包含 Apple/Android SDK、ADB 或第三方二进制；这些外部工具由开发者单独安装。
