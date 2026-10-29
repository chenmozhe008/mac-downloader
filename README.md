<div align="center">

<img src="docs/images/icon.png" width="128" alt="闪电全能下载图标">

# 闪电全能下载

一个 Mac 下载工具，磁力、BT、网盘、视频网站都能下

![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-555)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-orange?logo=swift)

<img src="docs/images/home.png" alt="闪电全能下载" width="900">

</div>

磁力链接、种子、ed2k、普通下载链接、网盘直链，以及 YouTube、B 站、抖音、小红书等视频网站的视频，都在同一个窗口里下载。装好浏览器扩展后，在网页上点下载会直接交给它。

原生 SwiftUI 应用，界面中文。

## 主要特点

- **什么都能下**：自动识别链接类型，按类型存到不同位置。复制链接后按 ⌘V，或把链接、种子文件拖进窗口即可
- **视频网站**：YouTube、B 站、X、微博直接粘贴链接；抖音、小红书、新片场在浏览器里打开视频页，点扩展里的「下载这个视频」。默认下载最高画质，优先 H.264，剪辑软件可直接使用；抖音、小红书无水印
- **BT 更快起速**：自动更新 tracker 列表、固定监听端口；重启后不用重新校验已下载的部分
- **边下边播**：下载中的电影可以直接播放，拖动进度条会优先下载对应位置
- **浏览器接管**：在网页上点下载，自动交给闪电全能下载；它没打开时，浏览器照常下载
- **云盘离线（可选）**：BT 没人分享时，可交给 PikPak 服务器下好，再从云盘拉回
- **菜单栏显示速度**：关闭窗口后下载继续

## 安装

需要 macOS 14 或更新版本，Apple Silicon（M 系列芯片）。

1. 在 [Releases](../../releases) 下载 `Shandian-版本号.zip`，解压后把 App 拖进「应用程序」
2. **第一次打开**：这个 App 没有经过苹果公证，双击时系统会提示「无法验证开发者」。点「完成」，然后打开「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」。以后正常双击即可
3. **下载视频网站需要 ffmpeg**（合并画面和声音）：装了 [Homebrew](https://brew.sh) 的话，在终端运行 `brew install ffmpeg`

第一次打开时会自动下载 yt-dlp（视频网站下载组件），之后每周自动检查更新。下载 YouTube、X 等境外网站需要本机已开启代理，闪电全能下载会跟随系统代理设置。

## 装浏览器扩展

装好后在网页上点下载会直接交给闪电全能下载；下载抖音、小红书、新片场的视频也要用它。支持 Chrome 和 Edge。

1. 在闪电全能下载顶部菜单栏选「闪电全能下载 → 浏览器扩展…」，窗口里点「Chrome」或「Edge」，打开浏览器的扩展管理页
2. 在扩展管理页打开「开发者模式」：Chrome 在页面右上角，Edge 在左侧栏
3. 回到闪电全能下载的窗口，点「显示文件夹」，把 `BrowserExtension` 文件夹拖进浏览器的扩展管理页

装好后，窗口里会显示「已连接」。扩展会跟着 App 自动更新。

**下载视频网站的视频**：打开视频页，点浏览器工具栏里的闪电全能下载图标，再点「下载这个视频」；也可以在视频画面上右键，选「用闪电全能下载」。

## 支持的来源

| 来源 | 用法 |
| --- | --- |
| 磁力链接、种子、ed2k | 粘贴链接，或把种子文件拖进窗口 |
| 普通下载链接 | 粘贴链接，或装好扩展后在网页上直接点下载 |
| 网盘 | 百度网盘等需要先在网页里取得直链：另装篡改猴和 [LinkSwift](https://greasyfork.org/scripts/583582-linkswift) 脚本，直链会推送给闪电全能下载 |
| YouTube、X、B 站、微博 | 粘贴视频页链接 |
| 抖音、小红书、新片场 | 在浏览器里打开视频页，用扩展下载 |

视频号暂不支持。

## 从源码构建

```bash
swift build -c release                # 只编译 App
./script/build_engine.sh              # 编译下载内核（需要 Go，见脚本里的路径说明）
./script/build_app.sh package         # 打包成 dist/闪电全能下载.app
```

下载内核是打了补丁的 [Gopeed](https://github.com/GopeedLab/gopeed) v1.9.3，补丁在 `engine/shandian-gopeed-v1.9.3.patch`：重启不用重新校验、全局限速、边下边播、服务器限流时退避重试等。`build_engine.sh` 和 `build_app.sh` 里的路径是作者本机的，构建前请按自己的环境修改。

## 致谢

- [Gopeed](https://github.com/GopeedLab/gopeed)（GPL-3.0）：下载内核
- [yt-dlp](https://github.com/yt-dlp/yt-dlp)（Unlicense）：视频网站下载
- [FFmpeg](https://ffmpeg.org)：合并音视频

## 声明

仅供个人下载自己有权获取的内容，请遵守各网站的服务条款和当地法律法规。

## 许可证

[GPL-3.0](LICENSE)
