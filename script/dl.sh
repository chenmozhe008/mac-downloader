#!/bin/bash
# dl.sh "<链接或本地.torrent>" —— 统一入口：按类型分给内核（磁力/种子/ed2k/HTTP）或 yt-dlp（视频网站）
# 落盘：影视类 → /Volumes/Jack Feng/movies；视频网站 → ~/Downloads/视频；其余 → ~/Downloads
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ENGINE_TOKEN=$(python3 -I -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/ShandianDownload/engine.json")))["token"])')
API="http://127.0.0.1:9999/api/v1"; LINK="$1"
MOVIES="/Volumes/Jack Feng/movies"; VIDEOS="$HOME/Downloads/视频"; FILES="$HOME/Downloads"
[ -n "$LINK" ] || { echo "用法: dl.sh <链接>"; exit 1; }

video_site(){ echo "$1" | grep -qiE '^https?://([a-z0-9-]+\.)*(bilibili\.com|b23\.tv|youtube\.com|youtu\.be|douyin\.com|xiaohongshu\.com|xhslink\.com|kuaishou\.com|weibo\.com|ixigua\.com|vimeo\.com|x\.com|twitter\.com)/'; }

if video_site "$LINK"; then
  mkdir -p "$VIDEOS"
  # 视频站走代理（境外站必须；国内站经 Clash 规则直连）
  # 用 App 自带、每周自更新的 yt-dlp（brew 里的旧版下 B 站会 412）
  YTDLP="$HOME/Library/Application Support/ShandianDownload/bin/yt-dlp"; [ -x "$YTDLP" ] || YTDLP=yt-dlp
  exec "$YTDLP" --proxy http://127.0.0.1:7897 -P "$VIDEOS" -o "%(title).80s [%(id)s].%(ext)s" \
    -f "bv*+ba/b" -S "res,vcodec:h264,acodec:aac" --merge-output-format mp4 --no-playlist "$LINK"
fi

case "$LINK" in
  magnet:*|ed2k:*|*.torrent) DIR="$MOVIES" ;;
  *) DIR="$FILES" ;;
esac
URL="$LINK"; [ -f "$LINK" ] && URL="data:application/x-bittorrent;base64,$(base64 -i "$LINK" | tr -d '\n')"
[ -d "$DIR" ] || { echo "目录不在：$DIR（移动硬盘没插？）"; exit 1; }
body=$(python3 -I -c 'import json,sys;print(json.dumps({"req":{"url":sys.argv[1]},"opts":{"path":sys.argv[2]}}))' "$URL" "$DIR")
curl -s -H "X-Api-Token: $ENGINE_TOKEN" -X POST "$API/tasks" -H 'Content-Type: application/json' -d "$body" \
  | python3 -I -c 'import json,sys;r=json.load(sys.stdin);print("已加入 →",sys.argv[1],"任务",r["data"]) if r["code"]==0 else sys.exit("失败: "+r["msg"])' "$DIR"
