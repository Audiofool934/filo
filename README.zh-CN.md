# filo

**少一点折腾，多一点听歌。**

一个给 Mac 和 DAC 用的免费、开源菜单栏小工具。
继续用 Apple Music 听歌，让 filo 根据识别到的曲目格式匹配设备输出，少开几次「音频 MIDI 设置」。

**[下载 Mac 版](https://github.com/Audiofool934/filo/releases/latest/download/filo-macos-universal.dmg)** · [安装说明](docs/INSTALL.zh-CN.md) · [English](README.md)

macOS 14.4 及以上 · Apple Silicon 与 Intel 通用 · MIT 开源

> 当前下载版本尚未通过 Apple 公证，macOS 可能会拦截首次打开。
> 安装前请看[首次打开说明](docs/INSTALL.zh-CN.md#首次打开)。

<p align="center">
  <img src="docs/images/filo-card.jpg" width="340" alt="filo 的圆角菜单栏卡片：Apple Music 连接 WALKMAN，192 kHz，Matched，24-bit">
</p>

## 为听歌留一点空间

- **格式跟着音乐走：** 识别到 Apple Music 的曲目格式后，匹配设备支持的采样率和已知整数位深。
- **操作很少：** 选好播放器和 DAC，打开一个开关。
- **安静待在菜单栏：** 一枚小小的 ƒ，点开是固定尺寸、没有顶部箭头的卡片。
- **有一点听歌的仪式感：** macOS 26 上的原生 Liquid Glass，以及随采样率变化的 CD、录音室和 Hi-Fi 场景。

场景只是气氛，不代表音质等级。
较早的 macOS 使用系统材质作为替代。

## 支持哪些播放器？

| 播放器 | 当前支持 |
| --- | --- |
| Apple Music | 根据可用的无损解码信息或可访问的本地文件，自动匹配设备支持的格式。 |
| Spotify | 固定 44.1 kHz 音乐配置和手动采样率选择，暂不逐曲识别源格式。 |

无法识别源格式或设备不支持目标采样率时，filo 保留当前输出采样率。
设备没有完全相同的整数位深时，尽可能选择精度足够的格式，并显示限制。

## 开始听歌

1. [下载 DMG](https://github.com/Audiofool934/filo/releases/latest/download/filo-macos-universal.dmg)，打开后把 **filo** 拖进「应用程序」。
2. 接上 USB DAC；如果设备有 USB DAC 模式，先打开它。
3. 启动 filo，点菜单栏里的 **ƒ**，选择 **Apple Music** 和输出设备。
4. 打开 **Automatic** 开关，按提示允许读取播放信息，然后在 Music 里开始播放一首无损歌曲。

使用 Spotify 时，选择 **Spotify profile**，目标固定为 44.1 kHz。
默认的 Format matching 不需要额外音频驱动或录音权限。

连接后，选中的设备会成为 Mac 的默认媒体输出。
断开时，filo 会恢复仍由自己管理的设置；你在其他地方做的修改优先。
Mac 休眠或 DAC 拔插后，需要重新连接。

[安装与首次打开](docs/INSTALL.zh-CN.md) · [完整使用说明（英文）](docs/USAGE.md) · [更新记录与校验文件](https://github.com/Audiofool934/filo/releases/latest)

## 看清状态，安心听歌

**Matched** 表示输出采样率与 filo 观察到的源信息一致。
它不代表端到端 bit-perfect 认证，也不承诺可听出的音质提升。
格式识别可能延迟或暂时不可用，DAC 切换采样率时也可能短暂停顿。

filo 免费使用，无账号、无遥测，不上传音频。
默认模式只管理设备设置，播放仍由你的播放器完成。
播放器音量、EQ 和其他音效由你自己控制。

Settings 中还保留了 Direct relay 和 Exclusive preview 实验功能，各自有额外的权限和依赖要求。
日常听歌使用默认的 Format matching 即可。

## 你的设备用起来怎么样？

[反馈使用体验或问题](https://github.com/Audiofool934/filo/issues/new/choose)，告诉我们 macOS 版本、播放器、DAC 型号和具体情况。
需要时可以从 **••• → Connection details → Copy diagnostics** 复制诊断摘要，检查后再贴出，不需要上传音乐文件。

[源码构建（英文）](README.md#build-and-explore) · [贡献指南](CONTRIBUTING.md) · [验证记录](docs/VALIDATION.md) · [技术说明与实验室](docs/TECHNICAL-NOTES.md)

项目采用 [MIT 许可证](LICENSE)。
filo 来自意大利语中的「线」。
