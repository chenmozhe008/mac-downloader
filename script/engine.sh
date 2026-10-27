#!/bin/bash
# engine.sh start|stop|status|configure —— 管理下载内核（Gopeed headless）
# 内核与任务库在移动硬盘；只监听 127.0.0.1；token 读项目 .env
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="/Volumes/Jack Feng/Applications/MacDownloader"
PORT=9999
source "$ROOT/.env"
API="http://127.0.0.1:$PORT/api/v1"
api(){ curl -s -H "X-Api-Token: $ENGINE_TOKEN" "$@"; }

case "$1" in
  start)
    [ -x "$ENGINE_DIR/gopeed" ] || { echo "内核不在：$ENGINE_DIR（移动硬盘没插？）"; exit 1; }
    if api "$API/info" >/dev/null 2>&1 && api "$API/info" | grep -q '"code":0'; then echo "已在运行"; exit 0; fi
    mkdir -p "$ROOT/logs"
    cd "$ENGINE_DIR" && nohup ./gopeed -A 127.0.0.1 -P $PORT -T "$ENGINE_TOKEN" -d "$ENGINE_DIR/data" \
      -c "$ENGINE_DIR/data/server.json" >> "$ROOT/logs/engine.log" 2>&1 &
    for i in $(seq 20); do sleep 0.5; api "$API/info" 2>/dev/null | grep -q '"code":0' && { echo "已启动 :$PORT"; exit 0; }; done
    echo "启动失败，看 logs/engine.log"; exit 1 ;;
  stop) pkill -f "$ENGINE_DIR/gopeed|./gopeed -A 127.0.0.1 -P $PORT" && echo 已停止 || echo 未运行 ;;
  status) api "$API/info"; echo ;;
  configure)
    # 下载设置：目录、代理、BT 固定监听端口、HTTP 连接数（国内镜像 16 线程会被 403/418，取 8）
    # tracker 两个源合并去重（headless 内核没有桌面版的订阅功能，不填磁力解析会很慢）
    TRK=$(mktemp); for u in https://cf.trackerslist.com/best.txt https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt; do
      curl -s -m 15 "$u" >> "$TRK"; echo >> "$TRK"; done
    cfg=$(api "$API/config" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)["data"]
trk=list(dict.fromkeys(l.strip() for l in open(sys.argv[1]) if "announce" in l))
if trk: d["protocolConfig"].setdefault("bt",{})["trackers"]=trk
print(json.dumps(d))' "$TRK")
    rm -f "$TRK"
    cfg=$(echo "$cfg" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
d["downloadDir"]=__import__("os").path.expanduser("~/Downloads")
d["maxRunning"]=5
d["proxy"]={"enable":True,"system":False,"scheme":"http","host":"127.0.0.1:7897","usr":"","pwd":""}
d["protocolConfig"].setdefault("http",{})["connections"]=8
d["protocolConfig"].setdefault("bt",{})["listenPort"]=6881
print(json.dumps(d))')
    api -X PUT "$API/config" -H 'Content-Type: application/json' -d "$cfg"; echo ;;
  *) echo "用法: engine.sh start|stop|status|configure"; exit 1 ;;
esac
