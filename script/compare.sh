#!/bin/bash
# compare.sh "<磁力|链接|本地.torrent>" [每边秒数=180] [顺序: gt|tg|g|t,默认 gt]
# 一边一边测,不同时跑:测 Gopeed 时暂停它所有其他任务;测迅雷前先退出迅雷(关自动续传)清掉旧任务。
# 记录首字节耗时、均速,并同时记网卡总流量(明显高于被测者=有别的程序抢带宽)。
LINK="$1"; DUR="${2:-180}"; ORDER="${3:-gt}"
S="$HOME/Library/Caches/gopeed.sock"; BASE="/Volumes/Jack Feng/movies/_speedtest"; TD="$BASE/thunder"
mkdir -p "$BASE/gopeed" "$TD"; DLFAST="$HOME/.claude/skills/download-movie/scripts/dl_fast.sh"
en0(){ netstat -ibn | awk '/^en0 .*Link/{print $7; exit}'; }
mbps(){ awk -v d=$1 -v t=$2 'BEGIN{printf "%.2f",d/t/1048576}'; }
LOG=""

run_g(){
  [ -S "$S" ] || { echo "Gopeed 没开"; return; }
  curl -s --unix-socket "$S" -X PUT http://x/api/v1/tasks/pause >/dev/null
  local url="$LINK"; [ -f "$LINK" ] && url="data:application/x-bittorrent;base64,$(base64 -i "$LINK" | tr -d '\n')"
  local body; body=$(python3 -I -c 'import json,sys;print(json.dumps({"req":{"url":sys.argv[1]},"opts":{"path":sys.argv[2]}}))' "$url" "$BASE/gopeed")
  local GID; GID=$(curl -s --unix-socket "$S" -X POST http://x/api/v1/tasks -H 'Content-Type: application/json' -d "$body" | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["data"])')
  local t0 n0 first="" curve="" d=0 st e; t0=$(date +%s); n0=$(en0)
  while (( $(date +%s)-t0 < DUR )); do
    sleep 5; read d st <<<"$(curl -s --unix-socket "$S" http://x/api/v1/tasks/$GID | python3 -I -c 'import json,sys;t=json.load(sys.stdin)["data"];print(t["progress"]["downloaded"],t["status"])')"
    e=$(( $(date +%s)-t0 )); [ -z "$first" ] && [ "$d" -gt 0 ] && first=$e
    (( e % 30 < 5 )) && curve="$curve $((d/1048576))"; [[ $st == done || $st == error ]] && break
  done
  e=$(( $(date +%s)-t0 )); curl -s --unix-socket "$S" -X PUT http://x/api/v1/tasks/$GID/pause >/dev/null
  local l="Gopeed | $st | 首字节 ${first:-无}s | ${e}s 下了 $((d/1048576))MB | 均速 $(mbps $d $e) MB/s | 网卡均速 $(mbps $(( $(en0)-n0 )) $e) | 每30s累计MB:$curve"
  echo "$l"; LOG="$LOG$l"$'\n'
}

run_t(){
  local OLD_P OLD_A; OLD_P=$(defaults read com.xunlei.Thunder LastSavePath); OLD_A=$(defaults read com.xunlei.Thunder automaticStartTask)
  defaults write com.xunlei.Thunder automaticStartTask -int 0
  osascript -e 'quit app "Thunder"' 2>/dev/null; sleep 3; pkill -f "Thunder.app/Contents/XPCServices/DownloadService" 2>/dev/null; sleep 1
  defaults write com.xunlei.Thunder LastSavePath "$TD"
  local b0 t0 n0 first="" curve="" d=0 e; b0=$(du -sk "$TD" | awk '{print $1*1024}'); t0=$(date +%s); n0=$(en0)
  if [ -f "$LINK" ]; then open -a Thunder "$LINK"; sleep 4; SAVE_DIR="$TD" bash "$DLFAST" >/dev/null 2>&1
  else SAVE_DIR="$TD" bash "$DLFAST" "$LINK" >/dev/null 2>&1; fi
  while (( $(date +%s)-t0 < DUR )); do
    sleep 5; d=$(( $(du -sk "$TD" | awk '{print $1*1024}')-b0 )); e=$(( $(date +%s)-t0 ))
    [ -z "$first" ] && [ "$d" -gt 1048576 ] && first=$e; (( e % 30 < 5 )) && curve="$curve $((d/1048576))"
  done
  e=$(( $(date +%s)-t0 ))
  defaults write com.xunlei.Thunder LastSavePath "$OLD_P"; defaults write com.xunlei.Thunder automaticStartTask -int "$OLD_A"
  local l="迅雷   | 首字节 ${first:-无}s | ${e}s 下了 $((d/1048576))MB | 均速 $(mbps $d $e) MB/s | 网卡均速 $(mbps $(( $(en0)-n0 )) $e) | 每30s累计MB:$curve"
  echo "$l"; LOG="$LOG$l"$'\n'
}

for (( i=0; i<${#ORDER}; i++ )); do case ${ORDER:$i:1} in g) run_g;; t) run_t;; esac; done
printf '%s %s\n%s\n' "$(date '+%F %T')" "$(echo "$LINK" | cut -c1-120)" "$LOG" >> "$BASE/对比记录.txt"
