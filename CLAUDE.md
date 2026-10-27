# 闪电下载（mac-downloader）

> App 名「闪电下载」（10-27 用户定：先叫这个，后面再改），可执行名 `Shandian`，bundle id `io.github.chenmozhe008.shandian`

自用 Mac 下载器，目标是替代迅雷：磁力/BT/ed2k/HTTP + 视频网站 + 网盘直链，一个客户端搞定，浏览器一点就下。
方案与阶段：`docs/PLAN.md`（P0 规则 → P1 引擎 → P2 界面 → P3 浏览器与网盘 → P4 切换）。

## 架构（不自己写下载引擎）

- **内核**：Gopeed headless（`gopeed-web` v1.9.3 arm64），REST API `127.0.0.1:9999`，请求头 `X-Api-Token`；token 由 App 首次运行生成，存 `~/Library/Application Support/ShandianDownload/engine.json`（600 权限，不在仓库里），脚本也读这里
  - App 启动时自己拉起内核、退出时关掉；硬盘后插上会自动拉起
  - 内核二进制和任务库在移动硬盘 `/Volumes/Jack Feng/Applications/MacDownloader/`（用户要求装在硬盘）；硬盘没插时内核起不来，脚本会直接报出来
  - 只监听 127.0.0.1，不开 0.0.0.0
- **视频网站**：yt-dlp + ffmpeg，走代理 7897。**yt-dlp 用 App 自带的**（`Application Support/ShandianDownload/bin/yt-dlp`，首次启动下载官方 `yt-dlp_macos`、每 7 天 `-U`），brew 里的只做兜底——视频站改版快，10-27 实测 brew 的 2025-04 版下 B 站 412
  - 选格式 `-S res,vcodec:h264,acodec:aac`：默认会挑体积最小的 AV1（实测拿到 480P AV1），剪辑软件兼容差
- **网盘**：浏览器里的 LinkSwift 油猴脚本拿直链 → 交给内核。**只装 Greasy Fork 上 hmjz100 的版本**；GitHub `Mario82del/LinkSwift` 发安装包，疑似冒名，别碰
- 客户端界面（P2）：原生 SwiftUI，`NavigationSplitView` 系统侧栏 + 系统工具栏/搜索框（10-27 用户嫌手搓侧栏和红绿灯对不齐，别再手工画侧栏）；侧栏顶部 App 图标+名字，技术约定沿用小清（`Coding Project/mac-cleanup-manager/CLAUDE.md`）：本机 SwiftUI 宏编译不过，状态放 `ObservableObject @Published`；文案像专业 Mac 软件

## 入口与本机端口

- `127.0.0.1:9999` 内核 REST；`127.0.0.1:6800` App 内置网关（`Gateway.swift`）：`/jsonrpc` 兼容 Aria2 RPC（LinkSwift 推网盘直链），`/api/v1/*` 代理 Gopeed 浏览器扩展（新建任务改走 App 的添加流程：存哪、只选正片、片名整理），密钥都是内核 token
- `shandian://add?url=<编码后的链接>`（可多个 url）：脚本 / skill 交链接给 App，`open -g` 不抢焦点。**测试别再用 System Events 模拟 ⌘V**（窗口没抢到焦点时按键会落到用户正在用的程序里，10-27 踩过）
- 磁力默认打开方式已改为闪电下载（10-27 用户同意）；`.torrent` 文件关联未改
- 浏览器扩展：商店页浏览器不允许自动化点击，只能用户自己点「添加」；App 菜单「浏览器扩展…」里有商店链接和地址/密钥复制
- 复制即弹（`ClipboardWatcher`）：App 不在前台时，复制磁力/ed2k/种子/网盘/视频站/常见文件链接 → 右上角浮窗；普通网页不弹
- 代理：启动时探测 Clash（`LocalProxy`），没开就全部直连

## 版本与更新记录（沿用小清）

- 版本号在 `script/build_app.sh` 的 `APP_VERSION`，构建号取 git 提交数。修问题升第三位，加功能升第二位
- 每次升版本在 `CHANGELOG.md` 顶部加一节；打包时拷进 App，「关于闪电下载 → 更新记录」直接读它，别另写一份。写法按正式更新说明（短句、陈述事实，不写口语）
- 「关于 → 介绍」的优势卡在 `AboutView.swift` 的 `IntroPage`，只写实测过的数据（下面「测速记录」），竞品只写查证过的事实

## 脚本

- `script/engine.sh start|stop|status|configure`：启停内核；`configure` 写下载设置（每次内核重装/任务库重建后跑一次）
- `script/dl.sh "<链接或本地.torrent>"`：统一入口，自动分流
- `script/build_app.sh [run|package]`：编译打包成 `dist/闪电下载.app`

## 下载设置（`configure` 写入，改值先改这里的说明）

| 项 | 值 | 依据 |
|---|---|---|
| 落盘 | 磁力/种子/ed2k → `/Volumes/Jack Feng/movies`；视频站 → `~/Downloads/视频`；其余 → `~/Downloads` | 用户主要下电影；普通文件不混进电影目录 |
| 代理 | 开，`127.0.0.1:7897`（Clash 规则模式，国内仍直连） | 海外源/网页种子被墙，实测这是比迅雷快的主因 |
| HTTP 连接数 | 8 | 清华/中科大/华为云镜像对 16 线程回 403/418（10-27 实测被封） |
| BT 监听端口 | 6881 固定 | 默认随机端口不利于被连入 |
| HTTP User-Agent | `ShandianDownload/<版本>`，不冒充浏览器（`EngineClient.userAgent`） | Go 的 TLS 握手配 Chrome UA 被中科大等镜像识别为伪装爬虫 403，Chrome 116/141 都拦，如实写工具名才放行（10-27 实测）；要浏览器身份的下载由插件带真实 UA/Cookie |
| tracker | 每次 configure 从 trackerslist.com + ngosang 合并拉取 | headless 内核没有桌面版的 tracker 订阅，空列表时磁力解析很慢 |

## 测速记录

- 10-27 公开片源对比（迅雷 vs Gopeed，一边一边测、每边 2 分钟）：磁力起速 64s vs 5s；海外种子 0 vs 5 MB/s；迅雷会员只在命中缓存时短暂爆发
- 新内核（tracker 全 + 固定端口）：同一海外种子 8–10 MB/s（桌面版 Gopeed 约 5）；HTTP 腾讯 CDN 峰值 41.6 MB/s（≈带宽上限）
- 对比脚本 `script/compare.sh`（迅雷部分复用 `~/.claude/skills/download-movie/scripts/dl_fast.sh`）
- 「比迅雷会员快」在一种情况做不到：迅雷服务器缓存命中的冷门资源。不要对用户承诺这一项

## 已知事项

- 视频站实测（10-27，最新 yt-dlp）：B 站不登录 1080P ✅、微博 1080P ✅；抖音要「新鲜 cookie」，匿名 ttwid 也 403 ❌；小红书 yt-dlp 自带测试笔记拿不到视频 ❌（待用真实链接复测）。B 站 1080P+/4K 要登录 cookie
- lux（iawia002/lux）最后发版 2024-05，抖音/小红书失效、B 站只有 480P，不用
- Gopeed API 新建任务参数是 `opts`（不是 `opt`），写错不报错、路径静默失效
- `download-movie` skill 暂不改（用户 10-27 说：测稳了再改）

## 目录

`script/` 脚本 · `docs/` 方案 · `tmp/` 临时（用完清）· `output/` 效果图等产物 · `logs/` 内核日志（gitignore）
