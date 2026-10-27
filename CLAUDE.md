# mac-downloader（工作名，正式名待定）

自用 Mac 下载器，目标是替代迅雷：磁力/BT/ed2k/HTTP + 视频网站 + 网盘直链，一个客户端搞定，浏览器一点就下。
方案与阶段：`docs/PLAN.md`（P0 规则 → P1 引擎 → P2 界面 → P3 浏览器与网盘 → P4 切换）。

## 架构（不自己写下载引擎）

- **内核**：Gopeed headless（`gopeed-web` v1.9.3 arm64），REST API `127.0.0.1:9999`，请求头 `X-Api-Token`，token 在项目 `.env` 的 `ENGINE_TOKEN`（永不入 git）
  - 内核二进制和任务库在移动硬盘 `/Volumes/Jack Feng/Applications/MacDownloader/`（用户要求装在硬盘）；硬盘没插时内核起不来，脚本会直接报出来
  - 只监听 127.0.0.1，不开 0.0.0.0
- **视频网站**：yt-dlp + ffmpeg（brew 已装），走代理 7897
- **网盘**：浏览器里的 LinkSwift 油猴脚本拿直链 → 交给内核。**只装 Greasy Fork 上 hmjz100 的版本**；GitHub `Mario82del/LinkSwift` 发安装包，疑似冒名，别碰
- 客户端界面（P2）：原生 SwiftUI，技术约定沿用小清（`Coding Project/mac-cleanup-manager/CLAUDE.md`）：本机 SwiftUI 宏编译不过，状态放 `ObservableObject @Published`；文案像专业 Mac 软件

## 脚本

- `script/engine.sh start|stop|status|configure`：启停内核；`configure` 写下载设置（每次内核重装/任务库重建后跑一次）
- `script/dl.sh "<链接或本地.torrent>"`：统一入口，自动分流

## 下载设置（`configure` 写入，改值先改这里的说明）

| 项 | 值 | 依据 |
|---|---|---|
| 落盘 | 磁力/种子/ed2k → `/Volumes/Jack Feng/movies`；视频站 → `~/Downloads/视频`；其余 → `~/Downloads` | 用户主要下电影；普通文件不混进电影目录 |
| 代理 | 开，`127.0.0.1:7897`（Clash 规则模式，国内仍直连） | 海外源/网页种子被墙，实测这是比迅雷快的主因 |
| HTTP 连接数 | 8 | 清华/中科大/华为云镜像对 16 线程回 403/418（10-27 实测被封） |
| BT 监听端口 | 6881 固定 | 默认随机端口不利于被连入 |
| tracker | 每次 configure 从 trackerslist.com + ngosang 合并拉取 | headless 内核没有桌面版的 tracker 订阅，空列表时磁力解析很慢 |

## 测速记录

- 10-27 公开片源对比（迅雷 vs Gopeed，一边一边测、每边 2 分钟）：磁力起速 64s vs 5s；海外种子 0 vs 5 MB/s；迅雷会员只在命中缓存时短暂爆发
- 新内核（tracker 全 + 固定端口）：同一海外种子 8–10 MB/s（桌面版 Gopeed 约 5）；HTTP 腾讯 CDN 峰值 41.6 MB/s（≈带宽上限）
- 对比脚本 `script/compare.sh`（迅雷部分复用 `~/.claude/skills/download-movie/scripts/dl_fast.sh`）
- 「比迅雷会员快」在一种情况做不到：迅雷服务器缓存命中的冷门资源。不要对用户承诺这一项

## 已知事项

- B 站不登录只有 480P；要高清需 `--cookies-from-browser`（P2/P3 再接）
- Gopeed API 新建任务参数是 `opts`（不是 `opt`），写错不报错、路径静默失效
- `download-movie` skill 暂不改（用户 10-27 说：测稳了再改）

## 目录

`script/` 脚本 · `docs/` 方案 · `tmp/` 临时（用完清）· `output/` 效果图等产物 · `logs/` 内核日志（gitignore）
