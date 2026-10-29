# 闪电全能下载（shandian-download，10-29 由 mac-downloader 改名）

> App 名「闪电全能下载」（10-29 用户定，原名「闪电下载」；卖点是常用渠道都能下 + 快；用户嫌「什么都能下」说得太满，对外别这么写）。**对外（README、推广图、文案、文章）不点名迅雷、Downie 等竞品做对比**，只写自己的实测数据（10-29 用户：以免引起商业纠纷），可执行名 `Shandian`，bundle id `io.github.chenmozhe008.shandian`

自用 Mac 下载器，目标是替代迅雷：磁力/BT/ed2k/HTTP + 视频网站 + 网盘直链，一个客户端搞定，浏览器一点就下。
方案与阶段：`docs/PLAN.md`（P0 规则 → P1 引擎 → P2 界面 → P3 浏览器与网盘 → P4 切换）。
实现细节与实测数据：`docs/internals.md`（补丁逐条说明、抖音/PikPak/扩展机制、测速记录）。本文件只放规则和红线。**仓库公开，这里和 docs/ 都别写真实片名等隐私**

## 架构（不自己写下载引擎）

- **内核**：Gopeed headless v1.9.3 **打了闪电全能下载补丁**（`engine/shandian-gopeed-v1.9.3.patch`，`script/build_engine.sh` 编译，产物打进 App、启动时换上），REST API `127.0.0.1:9999`，请求头 `X-Api-Token`；token 由 App 首次运行生成，存 `~/Library/Application Support/ShandianDownload/engine.json`（600 权限，不在仓库里），脚本也读这里
  - 内核程序和任务库在本机 `Application Support/ShandianDownload/engine/`（10-28 用户同意从移动硬盘挪来；硬盘上的旧副本 `/Volumes/Jack Feng/Applications/MacDownloader/` 没删，等用户定）
  - App 启动时没有就拉起；退出 App 只暂停任务、不关内核
  - 补丁 9 项（块记录落盘免重校验、全局限速、边下边播、429/5xx 退避、每段≥20 MB、probe 只探测、失败原因字段等），逐条见 `docs/internals.md`；补丁测试 `internal/protocol/http/shandian_test.go`
  - Go 工具链、Gopeed 源码、编译缓存都在移动硬盘 `Applications/ShandianBuild/`（不装全局）；**必须开 CGO**；`build_engine.sh` 用移动硬盘上 Xcode-26.5 的工具链（本机命令行工具链接器和 SDK 对不上）
  - 推出移动硬盘时内核会被暂停→结束→2 秒后重启（`EngineHost.holdsFiles`），插回自动续
  - 只监听 127.0.0.1，不开 0.0.0.0
- **视频网站**：yt-dlp + ffmpeg，国内站直连、境外站走系统代理。**yt-dlp 用 App 自带的目录版**（`Application Support/ShandianDownload/bin/yt-dlp_macos/`，单文件版启动慢 16 秒；每 7 天查最新 tag 重下），brew 版只做兜底
  - **参数带了 `--print` 必须同时带 `--progress`**，否则不出进度（用户：一直 0 突然下好）
  - 固定 `--concurrent-fragments 4`、`-S res,vcodec:h264,acodec:aac`（不设会挑 AV1）；别设 `--http-chunk-size`。依据见 `docs/internals.md`
- **网盘**：浏览器里的 LinkSwift 油猴脚本拿直链 → 交给内核。**只装 Greasy Fork 上 hmjz100 的版本**；GitHub `Mario82del/LinkSwift` 发安装包，疑似冒名，别碰
- 客户端界面（P2）：原生 SwiftUI，`NavigationSplitView` 系统侧栏 + 系统工具栏/搜索框（10-27 用户嫌手搓侧栏和红绿灯对不齐，别再手工画侧栏）；侧栏顶部 App 图标+名字，技术约定沿用小清（`Coding Project/mac-cleanup-manager/CLAUDE.md`）：本机 SwiftUI 宏编译不过，状态放 `ObservableObject @Published`；文案像专业 Mac 软件

## 入口与本机端口

- `127.0.0.1:9999` 内核 REST；`127.0.0.1:6800` App 内置网关（`Gateway.swift`）：`/jsonrpc` 兼容 Aria2 RPC（LinkSwift 推网盘直链），`/api/v1/*` 代理 Gopeed 浏览器扩展（新建任务改走 App 的添加流程：存哪、只选正片、片名整理），密钥都是内核 token
- `shandian://add?url=<编码后的链接>`（可多个 url）：脚本 / skill 交链接给 App，`open -g` 不抢焦点。**测试别再用 System Events 模拟 ⌘V**（窗口没抢到焦点时按键会落到用户正在用的程序里，10-27 踩过）
- 迅雷通道（`ThunderBridge.swift`，默认关）：BT 慢 3 分钟交给本机迅雷，靠辅助功能 API 点按钮、按文件夹占用量算进度。**不逆向迅雷协议、不碰会员**（用户多次要求 rev 迅雷，已拒绝：等于白用别人的商业服务）
- 云盘离线（`PikPak.swift`）：接口照开源 PikPakAPI。**不在 App 里输密码**（用户 10-28 定），用网页窗口打开官方登录页取令牌，只存 `pikpak.json`（600）；拉回后删云端文件；免费额度小，默认手动。BT 慢 3 分钟优先云盘、其次迅雷。签名常量会随 PikPak 改版变，细节见 `docs/internals.md`
- 回收站：移除任务写 `removed.json`（最多 500 条），可重新下载
- 磁力默认打开方式已改为闪电全能下载（10-27 用户同意）；`.torrent` 文件关联未改
- 浏览器扩展：**用自带的**（`browser-extension/`，MV3，Chrome / Edge 通用；10-28 用户说别绑篡改猴）。打包进 App、启动时拷到 `Application Support/ShandianDownload/BrowserExtension`（浏览器记路径，别指向 dist）。用户在扩展页开开发者模式、拖文件夹进去装一次——浏览器不允许第三方静默装扩展，Chrome 137+ 也不认 `--load-extension`
  - 扩展 ID 由 manifest 的 `key` 固定，网关 `/extension/*` 只认这个 Origin；**改 key 要同步改 `Gateway.extensionOrigin`**
  - 接管原则：App 接下了才取消浏览器的下载，App 失败就退回浏览器重下；图片/网页/<5 MB 不接。完整规则见 `docs/internals.md`
  - **抖音别改回包 fetch/XHR**（会和安全 SDK 防篡改死循环、页面卡死），只包 `JSON.parse` / `Response.prototype.json`；**所有视频入口都走 `downloadVideoInTab`**。抖音、小红书已实测，快手和抖音信息流未实测，视频号不接
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
| 代理 | 内核全局代理**关**；磁力/种子一律直连；HTTP 直链、视频站按域名判断（`LocalProxy.needed`）：国内站直连，其余单个任务走系统代理 | 全局开着时 BT 全绕 Clash、速度乱跳；用户定别一刀切 |
| HTTP 连接数 | 8 | 镜像站对 16 线程回 403/418 |
| BT 监听端口 | 6881 固定 | 默认随机端口不利于被连入 |
| HTTP User-Agent | `ShandianDownload/<版本>`，不冒充浏览器（`EngineClient.userAgent`） | 冒充 Chrome 被镜像站识别为爬虫 403；要浏览器身份的下载由扩展带真实 UA/Cookie |
| tracker | 每次 configure 从 trackerslist.com + ngosang 合并拉取 | headless 内核没有桌面版的 tracker 订阅，空列表时磁力解析很慢 |

## 测速

- 数据和对比脚本在 `docs/internals.md`「测速记录」。对外只用区间（磁力起速 5–18 秒），不写竞品数字
- 「比迅雷会员快」在一种情况做不到：迅雷服务器缓存命中的冷门资源。不要对用户承诺这一项

## 已知事项（踩坑警示）

- Gopeed API 新建任务参数是 `opts`（不是 `opt`），写错不报错、路径静默失效
- **磁力/种子任务绝不能带 `req.proxy`**：BT 客户端全内核只建一次，代理取第一个 BT 任务的设置，之后改不了（读 v1.9.3 源码确认）
- yt-dlp 抖音带登录 Cookie 也 403，所以抖音靠扩展拿页面里的视频地址当直链下；lux 已失效，不用
- 上传为 0 多半是对方不要数据或路由器没开 UPnP，不是上传被关（`cfg.Seed = true`）
- `download-movie` skill 10-28 改成 `dl_shandian.sh` → `shandian://add?confirm=0&url=…`（不弹确认框）；闪电全能下载不可用时退回迅雷 `dl_fast.sh`

## 仓库

GitHub **公开**库 `chenmozhe008/shandian-download`（10-28 建，10-29 用户同意公开，分支 master，GPL-3.0——内核基于 Gopeed GPL-3.0，只能用 GPL）。推送仍按全局红线先问用户
- 发布：`output/release/` 里拷一份 dist 的 App，**`codesign --force --deep --sign -` 改 ad-hoc 签名再打包**（本机用的 Apple Development 证书带用户邮箱，不能外发），`ditto -c -k --keepParent` 打 zip，`gh release create v<版本>`。**附件名用英文 `Shandian-<版本>.zip`**（中文名会被 GitHub 改成 default.zip）。v0.16.0 为首个公开版
- **install.sh 按附件名 `Shandian-*.zip` 找安装包**：发版改附件名要同步改脚本，否则一行命令安装失效
- 公开页面别放下载记录截图（有片名）；README 的安装步骤要和 App 里「浏览器扩展」窗口的按钮文字一致；对外数字用测速记录里的区间（磁力起速 5–18 秒），别挑最有利的单值，不带竞品对比
- 图标 10-29 定稿 J1（`Resources/icon/icon.html`：深橙底 + 原闪电箭头，和闪电说的黄橙区分）；菜单栏 18 点。别再换图形，改前先出方案给用户挑
- 推广图和文案在 `output/闪电全能下载-推广/`（源文件 `output/promo/`，Chrome 无头渲染 1080×1350 @2x）
- README 截图（`docs/images/screenshot-*.png`）是仿真图：`output/readme-shots/shot.html?page=active|library`，照 v0.16.0 界面手画、片名只用公版/开源片，Chrome 无头 1000×700 @2x 渲染。界面改版后要同步改这个 HTML 再重渲；README 措辞用产品说明的书面语、数字带测试条件（10-29 用户：「能下什么」这类话不像 App 该说的）。README 标题区（logo 下三行）和 GitHub About 简介 / topics（`gh repo edit`）是同一套说法，加减功能时两处一起改

## 目录

`script/` 脚本 · `docs/` 方案 · `tmp/` 临时（用完清）· `output/` 效果图等产物 · `logs/` 内核日志（gitignore）
