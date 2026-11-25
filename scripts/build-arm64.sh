#!/usr/bin/env bash
#
# ScopeSentry 服务端 + 扫描端 arm64 一键构建脚本
#
# 前置条件:
#   - 宿主机为 linux/arm64(或在 arm64 容器内运行),已安装 docker
#   - 与本仓库同目录下存在 ScopeSentry-Scan 源码(如 git clone https://github.com/Autumn-27/ScopeSentry-Scan)
#
# 产物:
#   - dist/ScopeSentry_linux_arm64_v1/ScopeSentry                 服务端二进制
#   - scan-build/dist/ScopeSentry-Scan_linux_arm64_v1/ScopeSentry-Scan  扫描端二进制
#   - scan-build/tools/linux/{katana,rad,rustscan,ksubdomain}     arm64 工具
#   - scopesentry-server-arm64:<SERVER_VER> / scopesentry-scan-arm64:<SCAN_VER>  镜像
#
# 注意事项(详见 docs/arm64-build.md):
#   1. 两侧仓库均有误提交的示例文件重复声明 main,必须按 goreleaser 方式单文件编译
#   2. ksubdomain 必须用 Autumn-27/ksubdomain(旧版 wgpsec v1.x 的 fork),
#      knownsec v0.7 重写版命令行语法与扫描端代码不兼容
#   3. go-rod 在线下载的 chromium 没有 arm64 版,容器内需 ROD_BROWSER_BIN 指向 apt 安装的 chromium
set -euo pipefail

SERVER_VER="${SERVER_VER:-v1.9.4}"
SCAN_VER="${SCAN_VER:-v1.9.1}"

SCAN_REPO="${SCAN_REPO:-$(pwd)/../ScopeSentry-Scan}"
SERVER_IMG="scopesentry-server-arm64:${SERVER_VER#v}"
SCAN_IMG="scopesentry-scan-arm64:${SCAN_VER#v}"

GOLDFLAGS_SERVER="-s -w -X github.com/Autumn-27/ScopeSentry/internal/constants.Version=${SERVER_VER}"

echo "==> [1/5] 编译服务端二进制(单文件,规避误提交的重复 main)"
mkdir -p dist/ScopeSentry_linux_arm64_v1
docker run --rm -v "$(pwd)":/src -w /src -e CGO_ENABLED=0 golang:1.24 sh -c \
  "go build -trimpath -ldflags '${GOLDFLAGS_SERVER}' -o dist/ScopeSentry_linux_arm64_v1/ScopeSentry ./cmd/main/main.go"
file dist/ScopeSentry_linux_arm64_v1/ScopeSentry

echo "==> [2/5] 编译扫描端二进制(单文件)"
mkdir -p "${SCAN_REPO}/dist/ScopeSentry-Scan_linux_arm64_v1"
docker run --rm -v "${SCAN_REPO}":/src -w /src -e CGO_ENABLED=0 golang:1.24 sh -c \
  "go build -trimpath -ldflags '-s -w' -o dist/ScopeSentry-Scan_linux_arm64_v1/ScopeSentry-Scan ./cmd/ScopeSentry/main.go"
file "${SCAN_REPO}/dist/ScopeSentry-Scan_linux_arm64_v1/ScopeSentry-Scan"

echo "==> [3/5] 下载 arm64 内置工具(katana/rad/rustscan 官方有 arm64 release)"
TOOLS_DIR=$(mktemp -d)
curl -sL --max-time 120 -o "${TOOLS_DIR}/katana.zip" \
  "https://github.com/projectdiscovery/katana/releases/download/v1.8.0/katana_1.8.0_linux_arm64.zip"
unzip -o -q "${TOOLS_DIR}/katana.zip" katana -d "${TOOLS_DIR}"

curl -sL --max-time 120 -o "${TOOLS_DIR}/rad.zip" \
  "https://github.com/chaitin/rad/releases/download/1.0/rad_linux_arm64.zip"
unzip -o -q "${TOOLS_DIR}/rad.zip" rad_linux_arm64 -d "${TOOLS_DIR}"

curl -sL --max-time 120 -o "${TOOLS_DIR}/rustscan.zip" \
  "https://github.com/RustScan/RustScan/releases/download/2.4.1/aarch64-linux-rustscan.zip"
unzip -o -q "${TOOLS_DIR}/rustscan.zip" -d "${TOOLS_DIR}"
RUSTSCAN_BIN=$(find "${TOOLS_DIR}" -maxdepth 1 -iname '*rustscan*' -type f | head -1)
trap 'rm -rf "${TOOLS_DIR}" "${KSUB_DIR:-}"' EXIT

echo "==> [4/5] 从 Autumn-27/ksubdomain 源码编译 arm64 ksubdomain(需 libpcap,CGO_ENABLED=1)"
KSUB_DIR=$(mktemp -d)
git clone --depth 1 https://github.com/Autumn-27/ksubdomain "${KSUB_DIR}"
docker run --rm -v "${KSUB_DIR}":/src -w /src golang:1.24-bookworm sh -c \
  "apt-get update -qq >/dev/null && apt-get install -y -qq libpcap-dev >/dev/null \
   && CGO_ENABLED=1 go build -trimpath -ldflags '-s -w' -o /src/ksubdomain-arm64 ./cmd/ksubdomain"
for f in "${TOOLS_DIR}/katana" "${TOOLS_DIR}/rad_linux_arm64" "${RUSTSCAN_BIN}" "${KSUB_DIR}/ksubdomain-arm64"; do
  file "$f" | grep -q 'ARM aarch64' || { echo "错误:$f 不是 arm64 二进制"; exit 1; }
done

echo "==> [5/5] 组装 scan-build 上下文并构建镜像"
mkdir -p scan-build/dist/ScopeSentry-Scan_linux_arm64_v1 scan-build/tools/linux
cp "${SCAN_REPO}/dist/ScopeSentry-Scan_linux_arm64_v1/ScopeSentry-Scan" scan-build/dist/ScopeSentry-Scan_linux_arm64_v1/
cp "${SCAN_REPO}/msyh.ttc" scan-build/
install -m 0755 "${TOOLS_DIR}/katana"                        scan-build/tools/linux/katana
install -m 0755 "${TOOLS_DIR}/rad_linux_arm64"               scan-build/tools/linux/rad
install -m 0755 "${RUSTSCAN_BIN}"                            scan-build/tools/linux/rustscan
install -m 0755 "${KSUB_DIR}/ksubdomain-arm64"               scan-build/tools/linux/ksubdomain

docker build -f dockerfile.arm64 -t "${SERVER_IMG}" .
docker build -t "${SCAN_IMG}" scan-build

echo
echo "构建完成:"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep -E "scopesentry-(server|scan)-arm64"
echo
echo "启动(首次需先生成 .env,见 docs/arm64-build.md):"
echo "  docker compose -f docker-compose.arm64.yml up -d"
