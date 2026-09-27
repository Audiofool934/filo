# 安装 filo

[English](INSTALL.md) · [返回项目首页](../README.zh-CN.md)

## 下载

需要 macOS 14.4 或更新版本。
同一个安装包同时支持 Apple Silicon 和 Intel Mac，无需选择芯片版本。
原生 Liquid Glass 需要 macOS 26，较早版本会使用系统材质替代。

1. [下载 filo Mac 版](https://github.com/Audiofool934/filo/releases/latest/download/filo-macos-universal.dmg)。
2. 打开 DMG，把 **filo** 拖到 **Applications（应用程序）** 文件夹。
   复制完成后，推出 filo 磁盘映像。
3. 从「应用程序」启动 filo，然后点击菜单栏里的 **ƒ**。

filo 没有 Dock 图标或独立主窗口。
也可以选择 [ZIP 版本](https://github.com/Audiofool934/filo/releases/latest/download/filo-macos-universal.zip)，解压后把 **filo.app** 拖进「应用程序」。
GitHub 页面上的 **Source code** 是留给自行编译的开发者的。
[更新记录与 SHA256SUMS 校验文件](https://github.com/Audiofool934/filo/releases/latest)与安装包放在同一个发布页面。

## 首次打开

1.1.2 的 DMG 和 ZIP 已完成 Developer ID 签名并通过 Apple 公证。
两种安装包都附带应用的公证凭据，DMG 也附带自己的公证凭据。
首次启动时，macOS 仍可能询问是否打开从互联网下载的应用，这是正常的首次确认，详见 [Apple 官方说明](https://support.apple.com/en-us/102445)。

如果 macOS 提示无法验证开发者，请先确认下载的是本仓库 Releases 中的 1.1.2 或更新版本；旧版本尚未公证。
如果当前版本仍被拦截，或提示应用「已损坏」「会损坏你的电脑」，先停止安装并[反馈原始提示](https://github.com/Audiofool934/filo/issues/new/choose)。

## 接上音乐

1. 连接 USB DAC；如果设备有 USB DAC 模式，先打开它。
2. 在 filo 里选择 **Apple Music** 和你的 DAC。
3. 打开 **Automatic**，如果 macOS 询问播放访问权限，按提示允许。
4. 在 Music 中开始播放一首无损歌曲。

默认的 **Format matching** 使用「自动化」权限读取所选播放器的播放信息。
这个模式不需要 BlackHole、新音频驱动、系统音频录制或麦克风权限。
这些额外依赖属于 Settings 里的可选实验功能。

使用 Spotify 时，选择 **Spotify profile**，目标固定为 44.1 kHz。
目前不会自动识别 Spotify 每首曲目的源格式。

如需无损播放，请在播放器里单独开启无损音质。
filo 不会替你修改音质、音量或音效设置。

## 遇到问题

- **Source format unknown：** 换一首无损 Music 曲目；如果仍无法识别，可断开后在 Settings 手动选择已知采样率。
- **找不到 DAC：** 检查 USB 连接，以及设备是否已进入 USB DAC 模式。
- **休眠或拔插以后：** 重新打开连接开关。
- **切换采样率时短暂停顿：** DAC 切换硬件采样率时可能出现这个现象。

更完整的格式、权限和恢复说明见[使用指南（英文）](USAGE.md)。

## 更新或卸载

更新时，先断开连接，通过 **••• → Quit filo** 退出，用新版本替换「应用程序」里的 filo.app，再打开并重新连接。
退出会释放当前连接，并恢复仍由 filo 管理的设备设置。

卸载时，同样先退出，再将 filo.app 移到废纸篓。
filo 不会安装驱动或管理员辅助程序。
