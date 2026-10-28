# 闪电下载（mac-downloader）

> App 名「闪电下载」（10-27 用户定：先叫这个，后面再改），可执行名 `Shandian`，bundle id `io.github.chenmozhe008.shandian`

自用 Mac 下载器，目标是替代迅雷：磁力/BT/ed2k/HTTP + 视频网站 + 网盘直链，一个客户端搞定，浏览器一点就下。
方案与阶段：`docs/PLAN.md`（P0 规则 → P1 引擎 → P2 界面 → P3 浏览器与网盘 → P4 切换）。

## 架构（不自己写下载引擎）

- **内核**：Gopeed headless v1.9.3 **打了闪电下载补丁**（`engine/shandian-gopeed-v1.9.3.patch`，`script/build_engine.sh` 编译，产物打进 App、启动时换上），REST API `127.0.0.1:9999`，请求头 `X-Api-Token`；token 由 App 首次运行生成，存 `~/Library/Application Support/ShandianDownload/engine.json`（600 权限，不在仓库里），脚本也读这里
  - 内核程序和任务库在本机 `Application Support/ShandianDownload/engine/`（10-28 用户同意从移动硬盘挪来；硬盘上的旧副本 `/Volumes/Jack Feng/Applications/MacDownloader/` 没删，等用户定）
  - App 启动时没有就拉起；退出 App 只暂停任务、不关内核
  - 补丁内容：①块完成记录落盘（bolt，`engine/data/piece-completion`）+ 关掉 .part 文件——anacrolix 用 .part 时启动会把没下完文件的块全标未完成，记录等于白存；②全局限速（config.extra.shandianDownloadLimit，KB/s，BT 和直链共用）；③`PUT /tasks/{id}/stream` 顺序下载、`GET /play/{id}/{key}/{名字}` 边下边送（key=sha256("shandian-play:"+token+":"+id) 前 24 位，播放器带不了请求头）；④新建任务前丢掉「解析」留下的同种子副本，否则文件写到默认目录
  - Go 工具链、Gopeed 源码、编译缓存都在移动硬盘 `Applications/ShandianBuild/`（不装全局）；**必须开 CGO**（不开 anacrolix 用纯 Go uTP，10-28 实测只剩 1 个连接）；本机命令行工具的链接器和 SDK 对不上，`build_engine.sh` 用移动硬盘上 Xcode-26.5 的工具链
  - 推出移动硬盘：DiskArbitration 推出审批回调里查内核是否开着那块盘上的文件（`EngineHost.holdsFiles`），开着就暂停→结束内核→批准→2 秒后重启，插回自动续
  - 只监听 127.0.0.1，不开 0.0.0.0
- **视频网站**：yt-dlp + ffmpeg，境外站走代理 7897，B 站/微博等国内站直连。**yt-dlp 用 App 自带的**（`Application Support/ShandianDownload/bin/yt-dlp`，首次启动下载官方 `yt-dlp_macos`、每 7 天 `-U`），brew 里的只做兜底——视频站改版快，10-27 实测 brew 的 2025-04 版下 B 站 412
  - 选格式 `-S res,vcodec:h264,acodec:aac`：默认会挑体积最小的 AV1（实测拿到 480P AV1），剪辑软件兼容差
- **网盘**：浏览器里的 LinkSwift 油猴脚本拿直链 → 交给内核。**只装 Greasy Fork 上 hmjz100 的版本**；GitHub `Mario82del/LinkSwift` 发安装包，疑似冒名，别碰
- 客户端界面（P2）：原生 SwiftUI，`NavigationSplitView` 系统侧栏 + 系统工具栏/搜索框（10-27 用户嫌手搓侧栏和红绿灯对不齐，别再手工画侧栏）；侧栏顶部 App 图标+名字，技术约定沿用小清（`Coding Project/mac-cleanup-manager/CLAUDE.md`）：本机 SwiftUI 宏编译不过，状态放 `ObservableObject @Published`；文案像专业 Mac 软件

## 入口与本机端口

- `127.0.0.1:9999` 内核 REST；`127.0.0.1:6800` App 内置网关（`Gateway.swift`）：`/jsonrpc` 兼容 Aria2 RPC（LinkSwift 推网盘直链），`/api/v1/*` 代理 Gopeed 浏览器扩展（新建任务改走 App 的添加流程：存哪、只选正片、片名整理），密钥都是内核 token
- `shandian://add?url=<编码后的链接>`（可多个 url）：脚本 / skill 交链接给 App，`open -g` 不抢焦点。**测试别再用 System Events 模拟 ⌘V**（窗口没抢到焦点时按键会落到用户正在用的程序里，10-27 踩过）
- 迅雷通道（`ThunderBridge.swift`，10-28）：BT 慢 3 分钟自动交给本机迅雷——设迅雷 LastSavePath、用迅雷打开链接、辅助功能 API 点「立即下载」；进度靠迅雷任务文件夹里非隐藏文件的实际占用量，文件夹按 `.<INFOHASH>.js`（迅雷的进度文件）认，`.js` 都没了算下完。**不逆向迅雷协议、不碰会员**（用户多次要求 rev 迅雷，已拒绝：等于白用别人的商业服务）
- 云盘离线（`PikPak.swift`，10-28 用户不想靠迅雷）：接口照开源 PikPakAPI（登录 captcha_init → signin；离线 POST /drive/v1/files UPLOAD_TYPE_URL；进度 /drive/v1/tasks；下载地址要 captcha 的 GET /drive/v1/files/{id} → web_content_link）。只存令牌 `pikpak.json`（600），不存密码；账号用户自己注册。BT 慢 3 分钟优先云盘、其次（开了的话）迅雷。**待用户注册账号后实测**
- 回收站：移除任务写 `removed.json`（最多 500 条），可重新下载
- 磁力默认打开方式已改为闪电下载（10-27 用户同意）；`.torrent` 文件关联未改
- 浏览器扩展：**用自带的**（`browser-extension/`，MV3，Chrome / Edge 通用；10-28 用户说别绑篡改猴）。打包进 App、启动时拷到 `Application Support/ShandianDownload/BrowserExtension`（浏览器记路径，别指向 dist）。用户在扩展页开开发者模式、拖文件夹进去装一次——浏览器不允许第三方静默装扩展，Chrome 137+ 也不认 `--load-extension`
  - 扩展 ID 由 manifest 的 `key` 固定为 `pggchniffhkcgigajlapkboikmgdipel`，网关 `/extension/*` 只认这个 Origin，不用密钥；改 key 要同步改 `Gateway.extensionOrigin`
  - 接管规则：App 接下了才取消浏览器那边的下载；App 没开浏览器照常下。网盘直链（LinkSwift）仍需篡改猴，设置页里折叠为可选
- 退出 App：`pauseAll` 后内核留着不关，下载中的任务记进 `resumeOnLaunch`，下次打开续上（补丁后内核重启也不用校验）
- 复制即弹（`ClipboardWatcher`）：App 不在前台时，复制磁力/ed2k/种子/网盘/视频站/常见文件链接 → 右上角浮窗；普通网页不弹
- 代理：启动时探测 Clash（`LocalProxy`），没开就全部直连；开着时只有境外 HTTP / 视频站任务走它，BT 不走

## 版本与更新记录（沿用小清）

- 版本号在 `script/build_app.sh` 的 `APP_VERSION`，构建号取 git 提交数。修问题升第三位，加功能升第二位
- 每次升版本在 `CHANGELOG.md` 顶部加一节；打包时拷进 App，「关于闪电下载 → 更新记录」直接读它，别另写一份。写法按正式更新说明（短句、陈述事实，不写口语）
- 「关于 → 介绍」的优势卡在 `AboutView.swift` 的 `IntroPage`，只写实测过的数据（下面「测速记录」），竞品只写查证过的事实

## 脚本

- `script/engine.sh start|stop|status|configure`：启停内核；`configure` 写下载设置（每次内核重装/任务库重建后跑一次）
- `script/dl.sh "<链接或本地.torrent>"`：统一入口，自动分流
- `script/build_app.sh [run|package]`：编译打包成 `dist/闪电下载.app`（会带上已编好的内核）
- `script/build_engine.sh`：下 Go、拉 Gopeed v1.9.3、打补丁、编译内核

## 下载设置（`configure` 写入，改值先改这里的说明）

| 项 | 值 | 依据 |
|---|---|---|
| 落盘 | 磁力/种子/ed2k → `/Volumes/Jack Feng/movies`；视频站和其余 → `~/Downloads`（10-28 用户定：视频网站不再单建「视频」） | 用户主要下电影；普通文件不混进电影目录 |
| 代理 | 内核全局代理**关**；磁力/种子一律直连；HTTP 直链、视频站按域名判断（`LocalProxy.needed`）：国内站直连，其余单个任务走 `127.0.0.1:7897` | 10-28 实测全局开着时 BT 连接全绕 Clash、上传为 0、速度几 KB～4 MB/s 乱跳；用户定：电影一般在国内下，YouTube 这类境外站才走代理，别一刀切 |
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

- 抖音、小红书（10-28 用户定的做法）：不在 App 里做登录，用户在浏览器里登录着，扩展右键「用闪电下载这个视频」把页面地址 + 这两家 Cookie 交给网关，存成 `Application Support/ShandianDownload/cookies-<douyin|xhs>.txt`（600）给 yt-dlp `--cookies`（`SiteCookies.swift`）；抖音 `?modal_id=` 地址扩展里换成 `/video/<id>`。**10-28 实测 yt-dlp 抖音带登录 Cookie 也 403**（网页 API 加了签名校验），所以扩展先在页面里找正在播的 `<video>` 真实地址（http 开头）直接交给内核当直链下，带 Referer/UA/Cookie；找不到才退回页面地址给 yt-dlp。**10-28 实测抖音不行**：播放器是 blob（MSE 分段），页面 RENDER_DATA 里也没有 playAddr，用户说抖音先不做；小红书待实测
- 视频站实测（10-27，最新 yt-dlp）：B 站不登录 1080P ✅、微博 1080P ✅；抖音要「新鲜 cookie」，匿名 ttwid 也 403 ❌；小红书 yt-dlp 自带测试笔记拿不到视频 ❌（待用真实链接复测）。B 站 1080P+/4K 要登录 cookie
- lux（iawia002/lux）最后发版 2024-05，抖音/小红书失效、B 站只有 480P，不用
- Gopeed API 新建任务参数是 `opts`（不是 `opt`），写错不报错、路径静默失效
- BT 客户端全内核只建一次（`internal/protocol/bt/fetcher.go initClient`），`cfg.HTTPProxy` 取**第一个** BT 任务的代理设置，之后改全局代理不生效、要重启内核。所以磁力/种子任务绝不能带 `req.proxy`（10-28 读 v1.9.3 源码确认）
- 上传：内核 `cfg.Seed = true`，上传没被关；《求救信号》上传一直 0 是对方不向我们要数据（迅雷用户为主），同时下的《希望》传了 49 MB。本机路由器 SSDP 发现不到 UPnP 网关（10-28），IPv4 下别人连不进来，要在路由器里开 UPnP；Mac 防火墙已放行 gopeed
- 原版重启内核会整片重新校验（Gopeed 用 .part 文件 + anacrolix 块记录只在内存），已由内核补丁解决；App 里「正在校验」（`checkFloor`）显示逻辑保留，换内核那次用得上
- 限速是补丁加的（原版没有）
- `download-movie` skill 10-28 改成 `dl_shandian.sh` → `shandian://add?confirm=0&url=…`（不弹确认框）；闪电下载不可用时退回迅雷 `dl_fast.sh`

## 目录

`script/` 脚本 · `docs/` 方案 · `tmp/` 临时（用完清）· `output/` 效果图等产物 · `logs/` 内核日志（gitignore）
