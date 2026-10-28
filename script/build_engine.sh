#!/bin/bash
# 编译打过补丁的 Gopeed 内核（闪电下载用）。补丁：engine/shandian-gopeed-v1.9.3.patch
#   - BT 块完成记录落盘 + 不用 .part 文件：重启内核不再整片重新校验
#   - 全局下载限速（BT 和直链共用，配置 extra.shandianDownloadLimit，KB/s）
#   - PUT /api/v1/tasks/{id}/stream：边下边播（按播放顺序下）
# Go 工具链和源码放移动硬盘 ShandianBuild/（不装全局），产物 ShandianBuild/gopeed-shandian，build_app.sh 会打进 App
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="/Volumes/Jack Feng/Applications/ShandianBuild"
PROXY=http://127.0.0.1:7897
mkdir -p "$B"
if [ ! -x "$B/go/bin/go" ]; then
  curl -sL -x $PROXY -o "$B/go.tgz" https://go.dev/dl/go1.24.11.darwin-arm64.tar.gz
  echo "a9c90c786e75d5d1da0547de2d1199034df6a4b163af2fa91b9168c65f229c12  $B/go.tgz" | shasum -a 256 -c -
  tar xzf "$B/go.tgz" -C "$B" && mv "$B/go.tgz" ~/.Trash/
fi
if [ ! -d "$B/gopeed-src" ]; then
  git -c http.proxy=$PROXY clone -q --depth 1 --branch v1.9.3 https://github.com/GopeedLab/gopeed.git "$B/gopeed-src"
  git -C "$B/gopeed-src" apply "$ROOT/engine/shandian-gopeed-v1.9.3.patch"
fi
mkdir -p "$B/gopeed-src/cmd/web/dist" && echo '<!doctype html><title>Shandian engine</title>' > "$B/gopeed-src/cmd/web/dist/index.html"
cd "$B/gopeed-src"
# CGO 关掉：本机命令行工具的链接器和 SDK 版本对不上（10-28），纯 Go 编译不受影响
PATH="$B/go/bin:$PATH" GOPATH="$B/gopath" GOMODCACHE="$B/gopath/pkg/mod" GOCACHE="$B/gocache" GOTOOLCHAIN=local \
  GOFLAGS=-mod=mod HTTPS_PROXY=$PROXY CGO_ENABLED=0 \
  go build -tags web -trimpath -ldflags "-s -w" -o "$B/gopeed-shandian" ./cmd/web
echo "内核：$B/gopeed-shandian"
