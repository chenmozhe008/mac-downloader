# 闪电全能下载（shandian-download，10-29 由 mac-downloader 改名）

> App 名「闪电全能下载」（10-29 用户定，原名「闪电下载」；卖点是常用渠道都能下 + 快；用户嫌「什么都能下」说得太满，对外别这么写，也别承诺比迅雷会员快），可执行名 `Shandian`，bundle id `io.github.chenmozhe008.shandian`

自用 Mac 下载器，目标是替代迅雷：磁力/BT/ed2k/HTTP + 视频网站 + 网盘直链，一个客户端搞定，浏览器一点就下。
方案与阶段：`docs/PLAN.md`（P0 规则 → P1 引擎 → P2 界面 → P3 浏览器与网盘 → P4 切换）。

## 架构（不自己写下载引擎）

- **内核**：Gopeed headless v1.9.3 **打了闪电全能下载补丁**（`engine/shandian-gopeed-v1.9.3.patch`，`script/build_engine.sh` 编译，产物打进 App、启动时换上），REST API `127.0.0.1:9999`，请求头 `X-Api-Token`；token 由 App 首次运行生成，存 `~/Library/Application Support/ShandianDownload/engine.json`（600 权限，不在仓库里），脚本也读这里
  - 内核程序和任务库在本机 `Application Support/ShandianDownload/engine/`（10-28 用户同意从移动硬盘挪来；硬盘上的旧副本 `/Volumes/Jack Feng/Applications/MacDownloader/` 没删，等用户定）
  - App 启动时没有就拉起；退出 App 只暂停任务、不关内核
  - 补丁内容：①块完成记录落盘（bolt，`engine/data/piece-completion`）+ 关掉 .part 文件——anacrolix 用 .part 时启动会把没下完文件的块全标未完成，记录等于白存；②全局限速（config.extra.shandianDownloadLimit，KB/s，BT 和直链共用）；③`PUT /tasks/{id}/stream` 顺序下载、`GET /play/{id}/{key}/{名字}` 边下边送（key=sha256("shandian-play:"+token+":"+id) 前 24 位，播放器带不了请求头）；④新建任务前丢掉「解析」留下的同种子副本，否则文件写到默认目录；⑤解析回 403 时带 `Range: bytes=0-` 重试（新片厂 xpccdn）；⑥429/5xx 指数退避（2→30 秒），连续 3 分钟没进展才放弃并报错（原版永不放弃、任务永远「下载中」）；⑦每段至少 20 MB（同 aria2 min-split-size），小文件 1 个连接；⑧`/resolve?probe=1` 只探测、立即关掉（原版解析会把 HTTP 文件整个预下载到 $TMPDIR 且不清，App 不用 rid 等于下两遍）；⑨任务字段 `shandianError` 存失败原因（App `EngineTask.failureText` 翻成人话）。补丁测试 `internal/protocol/http/shandian_test.go`
  - Go 工具链、Gopeed 源码、编译缓存都在移动硬盘 `Applications/ShandianBuild/`（不装全局）；**必须开 CGO**（不开 anacrolix 用纯 Go uTP，10-28 实测只剩 1 个连接）；本机命令行工具的链接器和 SDK 对不上，`build_engine.sh` 用移动硬盘上 Xcode-26.5 的工具链
  - 推出移动硬盘：DiskArbitration 推出审批回调里查内核是否开着那块盘上的文件（`EngineHost.holdsFiles`），开着就暂停→结束内核→批准→2 秒后重启，插回自动续
  - 只监听 127.0.0.1，不开 0.0.0.0
- **视频网站**：yt-dlp + ffmpeg，境外站走代理 7897，B 站/微博等国内站直连。**yt-dlp 用 App 自带的目录版**（`Application Support/ShandianDownload/bin/yt-dlp_macos/`，官方 `yt-dlp_macos.zip`；10-29 实测单文件版每次启动解包＋系统扫描白等 16 秒，目录版 0.3 秒。目录版不能 `-U`，每 7 天查 GitHub 最新 tag，不同就重下），brew 里的只做兜底——视频站改版快，10-27 实测 brew 的 2025-04 版下 B 站 412。**参数带了 `--print` 必须同时带 `--progress`**，否则安静模式不出进度（10-29 用户：一直 0 突然下好）；速度用最近 3 秒字节自己算，yt-dlp 报的瞬时值开头能到 200 MB/s
  - 分片并发 `--concurrent-fragments 4`：10-29 实测 YouTube 默认 1.4–1.6 MiB/s → 3.4–4.1；8、16 不比 4 明显快；`--http-chunk-size` 调大调小都不快，别设
  - 选格式 `-S res,vcodec:h264,acodec:aac`：默认会挑体积最小的 AV1（实测拿到 480P AV1），剪辑软件兼容差
- **网盘**：浏览器里的 LinkSwift 油猴脚本拿直链 → 交给内核。**只装 Greasy Fork 上 hmjz100 的版本**；GitHub `Mario82del/LinkSwift` 发安装包，疑似冒名，别碰
- 客户端界面（P2）：原生 SwiftUI，`NavigationSplitView` 系统侧栏 + 系统工具栏/搜索框（10-27 用户嫌手搓侧栏和红绿灯对不齐，别再手工画侧栏）；侧栏顶部 App 图标+名字，技术约定沿用小清（`Coding Project/mac-cleanup-manager/CLAUDE.md`）：本机 SwiftUI 宏编译不过，状态放 `ObservableObject @Published`；文案像专业 Mac 软件

## 入口与本机端口

- `127.0.0.1:9999` 内核 REST；`127.0.0.1:6800` App 内置网关（`Gateway.swift`）：`/jsonrpc` 兼容 Aria2 RPC（LinkSwift 推网盘直链），`/api/v1/*` 代理 Gopeed 浏览器扩展（新建任务改走 App 的添加流程：存哪、只选正片、片名整理），密钥都是内核 token
- `shandian://add?url=<编码后的链接>`（可多个 url）：脚本 / skill 交链接给 App，`open -g` 不抢焦点。**测试别再用 System Events 模拟 ⌘V**（窗口没抢到焦点时按键会落到用户正在用的程序里，10-27 踩过）
- 迅雷通道（`ThunderBridge.swift`，10-28）：BT 慢 3 分钟自动交给本机迅雷——设迅雷 LastSavePath、用迅雷打开链接、辅助功能 API 点「立即下载」；进度靠迅雷任务文件夹里非隐藏文件的实际占用量，文件夹按 `.<INFOHASH>.js`（迅雷的进度文件）认，`.js` 都没了算下完。**不逆向迅雷协议、不碰会员**（用户多次要求 rev 迅雷，已拒绝：等于白用别人的商业服务）
- 云盘离线（`PikPak.swift`，10-28 用户不想靠迅雷）：接口照开源 PikPakAPI（登录 captcha_init → signin；离线 POST /drive/v1/files UPLOAD_TYPE_URL；进度 /drive/v1/tasks；下载地址要 captcha 的 GET /drive/v1/files/{id} → web_content_link）。登录用 App 里的网页窗口打开 PikPak 官方登录页（用户 10-28：不要在 App 里输密码），读 localStorage 的 `credentials_<client_id>` 和 `deviceid` 后删掉网页那份，之后只由闪电全能下载刷新（网页端常量来自开源 peach ADR-0093 / AList，PikPak 改版可能失效）。只存令牌 `pikpak.json`（600）。拉回本地后删云端文件（免费 6 GB）。BT 慢 3 分钟优先云盘、其次（开了的话）迅雷。10-28 实测：国内热门片《年会不能停2》BT 为 0，PikPak 7.9 秒云端完成，拉回约 3 MB/s，自动删云端成功。网页端签名时间戳会随改版变（10-28 为 1793092691562，盐没变），设备号用 deviceid 最后一段前 32 位；签名被拒时 `refreshWebSign` 自动从网页脚本重取。免费约 3 次/天、20 GB/天、6 GB 空间，所以默认手动
- 回收站：移除任务写 `removed.json`（最多 500 条），可重新下载
- 磁力默认打开方式已改为闪电全能下载（10-27 用户同意）；`.torrent` 文件关联未改
- 浏览器扩展：**用自带的**（`browser-extension/`，MV3，Chrome / Edge 通用；10-28 用户说别绑篡改猴）。打包进 App、启动时拷到 `Application Support/ShandianDownload/BrowserExtension`（浏览器记路径，别指向 dist）。用户在扩展页开开发者模式、拖文件夹进去装一次——浏览器不允许第三方静默装扩展，Chrome 137+ 也不认 `--load-extension`
  - 扩展 ID 由 manifest 的 `key` 固定为 `pggchniffhkcgigajlapkboikmgdipel`，网关 `/extension/*` 只认这个 Origin，不用密钥；改 key 要同步改 `Gateway.extensionOrigin`
  - 接管规则：App 接下了才取消浏览器那边的下载；App 没开浏览器照常下（不拉起 App）。图片/文本/网页和已知 <5 MB 的不接（参照 IDM 默认不接图片）。接手后扩展每 5 秒问 `/extension/status` 共 5 分钟，App 那边失败就移除任务、扩展用浏览器重下（不再拦截）。用户主动点的（面板按钮、右键）App 没开就打开 `shandian://open`，等 ping 的 `ready`（内核就绪）再交。网盘直链（LinkSwift）仍需篡改猴，设置页里折叠为可选
- 退出 App：`pauseAll` 后内核留着不关，下载中的任务记进 `resumeOnLaunch`，下次打开续上（补丁后内核重启也不用校验）
- 复制即弹（`ClipboardWatcher`）：App 不在前台时，复制磁力/ed2k/种子/网盘/视频站/常见文件链接 → 右上角浮窗；普通网页不弹
- 代理：启动时读系统代理设置（`LocalProxy.check`，跟浏览器一致，不再写死 7897），没开或连不上就全部直连；开着时国内名单直连、其余 HTTP / 视频站走它（本机 Clash 是规则模式，漏在名单外的国内站也会被 Clash 直连），BT 不走
- 下载完成：打 com.apple.quarantine（`markQuarantine`，同浏览器）、放提示音 `Resources/done.wav`（`script/make_done_sound.py` 合成的上行五度「叮—咚」，不用迅雷的）；系统通知本身静音免得响两次

## 版本与更新记录（沿用小清）

- 版本号在 `script/build_app.sh` 的 `APP_VERSION`，构建号取 git 提交数。修问题升第三位，加功能升第二位
- 每次升版本在 `CHANGELOG.md` 顶部加一节；打包时拷进 App，「关于闪电全能下载 → 更新记录」直接读它，别另写一份。写法按正式更新说明（短句、陈述事实，不写口语）
- 「关于 → 介绍」的优势卡在 `AboutView.swift` 的 `IntroPage`，只写实测过的数据（下面「测速记录」），竞品只写查证过的事实

## 脚本

- `script/engine.sh start|stop|status|configure`：启停内核；`configure` 写下载设置（每次内核重装/任务库重建后跑一次）
- `script/dl.sh "<链接或本地.torrent>"`：统一入口，自动分流
- `script/build_app.sh [run|package]`：编译打包成 `dist/闪电全能下载.app`（会带上已编好的内核）。**不带参数＝run：会杀掉并重开用户正在用的 App**（App 就从 dist 运行）；只想编译验证用 `package`
- `script/build_engine.sh`：下 Go、拉 Gopeed v1.9.3、打补丁、编译内核
- `script/install.sh`：给别人用的一键安装（README 里 `curl … | bash`）：查 GitHub 最新 Release → 装进 /Applications → 去 quarantine → 有 brew 就装 ffmpeg。`SHANDIAN_DEST=<目录> SHANDIAN_TEST=1` 在临时目录测，不碰用户正在用的 App

## 下载设置（`configure` 写入，改值先改这里的说明）

| 项 | 值 | 依据 |
|---|---|---|
| 落盘 | 磁力/种子/ed2k → `/Volumes/Jack Feng/movies`；视频站和其余 → `~/Downloads`（10-28 用户定：视频网站不再单建「视频」） | 用户主要下电影；普通文件不混进电影目录 |
| 代理 | 内核全局代理**关**；磁力/种子一律直连；HTTP 直链、视频站按域名判断（`LocalProxy.needed`）：国内站直连，其余单个任务走系统代理（本机 `127.0.0.1:7897`） | 10-28 实测全局开着时 BT 连接全绕 Clash、上传为 0、速度几 KB～4 MB/s 乱跳；用户定：电影一般在国内下，YouTube 这类境外站才走代理，别一刀切 |
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

- 抖音、小红书（10-28 用户定的做法）：不在 App 里做登录，用户在浏览器里登录着，扩展右键「用闪电全能下载这个视频」把页面地址 + 这两家 Cookie 交给网关，存成 `Application Support/ShandianDownload/cookies-<douyin|xhs>.txt`（600）给 yt-dlp `--cookies`（`SiteCookies.swift`）；抖音 `?modal_id=` 地址扩展里换成 `/video/<id>`。**10-28 实测 yt-dlp 抖音带登录 Cookie 也 403**（网页 API 加了签名校验），所以扩展先在页面里找正在播的 `<video>` 真实地址（http 开头）直接交给内核当直链下，带 Referer/UA/Cookie；找不到才退回页面地址给 yt-dlp。**抖音（10-29 接通并经用户实测 ✅，1080P H.264 无水印、不用登录）**：扩展 `douyin-hook.js`（manifest content_scripts，document_start、world MAIN）在页面里包一层 `JSON.parse` / `Response.prototype.json`，记下页面自己请求到的 `aweme_detail` / `aweme_list`（签名 a_bogus 由抖音页面自己算，改算法不受影响；开源 TikTokDownloader/f2/Evil0ctal 都是自己算签名，f2 已 403）。**别改回包 fetch/XHR**：抖音安全 SDK 加载后会换掉它们（4 次 3 次被挤掉），用属性陷阱硬抢最外层会和它的防篡改死循环、页面卡死。同一条视频多个接口都有，「相关推荐」里只带低画质地址，只在更好时替换（H.264 > 分辨率 > 码率）。`v26-web.douyinvod.com` 要带抖音 Referer，扩展本来就带。**所有入口都要走 `downloadVideoInTab`**：右键视频画面的「用闪电全能下载」原来按链接处理、blob 就交页面地址给 yt-dlp，用户实测失败（1.11.2 修）。信息流（精选 / modal_id）按正在播的视频卡片 `data-e2e-vid` 取，**未实测**；快手 `<video>` 是普通 mp4，现有逻辑应能用，**未实测**；视频号不接（唯一能用的 wx_channels_download 要装共用私钥的根证书 + 接管系统代理）；**小红书 10-29 用户实测可下** ✅
- 视频站实测（10-27，最新 yt-dlp）：B 站不登录 1080P ✅、微博 1080P ✅；抖音要「新鲜 cookie」，匿名 ttwid 也 403 ❌；小红书 yt-dlp 自带测试笔记拿不到视频，真实链接走扩展 10-29 用户实测可下 ✅。B 站 1080P+/4K 要登录 cookie
- lux（iawia002/lux）最后发版 2024-05，抖音/小红书失效、B 站只有 480P，不用
- Gopeed API 新建任务参数是 `opts`（不是 `opt`），写错不报错、路径静默失效
- BT 客户端全内核只建一次（`internal/protocol/bt/fetcher.go initClient`），`cfg.HTTPProxy` 取**第一个** BT 任务的代理设置，之后改全局代理不生效、要重启内核。所以磁力/种子任务绝不能带 `req.proxy`（10-28 读 v1.9.3 源码确认）
- 上传：内核 `cfg.Seed = true`，上传没被关；《求救信号》上传一直 0 是对方不向我们要数据（迅雷用户为主），同时下的《希望》传了 49 MB。本机路由器 SSDP 发现不到 UPnP 网关（10-28），IPv4 下别人连不进来，要在路由器里开 UPnP；Mac 防火墙已放行 gopeed
- 原版重启内核会整片重新校验（Gopeed 用 .part 文件 + anacrolix 块记录只在内存），已由内核补丁解决；App 里「正在校验」（`checkFloor`）显示逻辑保留，换内核那次用得上
- 限速是补丁加的（原版没有）
- 维基百科原图（upload.wikimedia.org）对代理机房 IP 按频率随机放行（10-28 实测同一请求隔 3 秒约一半 429），浏览器单请求多试一次就过；闪电全能下载靠补丁⑥⑦（单连接 + 退避）
- `download-movie` skill 10-28 改成 `dl_shandian.sh` → `shandian://add?confirm=0&url=…`（不弹确认框）；闪电全能下载不可用时退回迅雷 `dl_fast.sh`

## 仓库

GitHub **公开**库 `chenmozhe008/shandian-download`（10-28 建，10-29 用户同意公开，分支 master，GPL-3.0——内核基于 Gopeed GPL-3.0，只能用 GPL）。推送仍按全局红线先问用户
- 发布：`output/release/` 里拷一份 dist 的 App，**`codesign --force --deep --sign -` 改 ad-hoc 签名再打包**（本机用的 Apple Development 证书带用户邮箱，不能外发），`ditto -c -k --keepParent` 打 zip，`gh release create v<版本>`。**附件名用英文 `Shandian-<版本>.zip`**（中文名会被 GitHub 改成 default.zip）。v0.16.0 为首个公开版
- **install.sh 按附件名 `Shandian-*.zip` 找安装包**：发版改附件名要同步改脚本，否则一行命令安装失效
- 公开页面别放下载记录截图（有片名）；README 的安装步骤要和 App 里「浏览器扩展」窗口的按钮文字一致；对外数字用测速记录里的区间（磁力起速 5–18 秒 vs 迅雷非会员 45–64 秒），别挑最有利的单值
- 图标 10-29 定稿 J1（`Resources/icon/icon.html`：深橙底 + 原闪电箭头，和闪电说的黄橙区分）；菜单栏 18 点。别再换图形，改前先出方案给用户挑
- 推广图和文案在 `output/闪电全能下载-推广/`（源文件 `output/promo/`，Chrome 无头渲染 1080×1350 @2x）
- README 截图（`docs/images/screenshot-*.png`）是仿真图：`output/readme-shots/shot.html?page=active|library`，照 v0.16.0 界面手画、片名只用公版/开源片，Chrome 无头 1000×700 @2x 渲染。界面改版后要同步改这个 HTML 再重渲；README 措辞用产品说明的书面语、数字带测试条件（10-29 用户：「能下什么」这类话不像 App 该说的）

## 目录

`script/` 脚本 · `docs/` 方案 · `tmp/` 临时（用完清）· `output/` 效果图等产物 · `logs/` 内核日志（gitignore）
