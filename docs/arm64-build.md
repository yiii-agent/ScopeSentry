# ScopeSentry arm64 构建与部署

官方发布的 `autumn27/scopesentry` / `autumn27/scopesentry-scan` 镜像**仅支持 amd64**,
本文档记录在 linux/arm64 宿主机上从源码编译、构建镜像并部署的全过程。
已在 Oracle ARM 实机验证(服务端 v1.9.4 + 扫描端 v1.9.1,4 容器全部 healthy)。

## 快速开始

```bash
# 1. 准备(与本仓库同目录放置 Scan 源码)
git clone https://github.com/Autumn-27/ScopeSentry
git clone https://github.com/Autumn-27/ScopeSentry-Scan

# 2. 一键构建(编译两侧二进制 + 4 个 arm64 工具 + 2 个镜像)
cd ScopeSentry && ./scripts/build-arm64.sh

# 3. 生成 .env(强随机密码,务必保留,勿提交;模板见 .env.example)
MONGO_PW=$(openssl rand -hex 16) && REDIS_PW=$(openssl rand -hex 16)
printf 'MONGO_INITDB_ROOT_USERNAME=admin\nMONGO_INITDB_ROOT_PASSWORD=%s\nREDIS_PASSWORD=%s\n' \
  "$MONGO_PW" "$REDIS_PW" > .env && chmod 600 .env

# 4. 启动
docker compose -f docker-compose.arm64.yml up -d

# 5. 查看首次初始化密码(程序自动生成,打印在日志并写入容器内 /opt/ScopeSentry/PASSWORD)
docker logs scope-sentry | grep -A3 'IMPORTANT NOTICE'
```

## 编译要点

| 组件 | 方式 | 关键参数 |
|---|---|---|
| 服务端 v1.9.4 | 源码编译 | `./cmd/main/main.go`,注入 `-X .../internal/constants.Version=v1.9.4` |
| 扫描端 v1.9.1 | 源码编译 | `./cmd/ScopeSentry/main.go` |
| katana v1.8.0 | 官方 release | `katana_1.8.0_linux_arm64.zip` |
| rad 1.0 | 官方 release | `rad_linux_arm64.zip` |
| rustscan 2.4.1 | 官方 release | `aarch64-linux-rustscan.zip` |
| ksubdomain | 源码编译 | `Autumn-27/ksubdomain`,`CGO_ENABLED=1` + `libpcap-dev` |

两侧均为纯 Go 项目,无 pcap 之外的原生依赖,在 arm64 宿主机上用 `golang:1.24` 容器原生编译即可。

## 注意事项

### 1. 误提交的示例文件导致整包编译失败
- 服务端 `cmd/main/basic_usage.go` 与扫描端 `cmd/ScopeSentry/` 下的
  `restructure_cmd.go` / `test_yaegi.go` 都是误提交的示例文件,
  与 `main.go` 同包重复声明 `func main`,整包编译报 `main redeclared`。
- 上游 `.goreleaser.yaml` 本来就按单文件构建,照做即可:
  分别指定 `./cmd/main/main.go` 和 `./cmd/ScopeSentry/main.go`。
- 源码未做任何修改,保持与上游一致。

### 2. ksubdomain 版本不兼容
- 扫描端代码按**旧版 wgpsec/ksubdomain v1.x** 的命令行编写(使用 `v` 子命令,
  见 `modules/subdomainscan/ksubdomain/ksubdomain.go` 自检逻辑)。
- knownsec/ksubdomain v0.7 是重写版(`-verify` flag 语法),编译后自检报 `run error`。
- 旧版 wgpsec 仓库已 404,其 v1.x 源码保存在作者自己的 fork:
  **https://github.com/Autumn-27/ksubdomain**(Go 1.17 + gopacket,可用 1.24 编译)。
- 必须用 `CGO_ENABLED=1` 并安装 `libpcap-dev`。

### 3. go-rod 浏览器(arm64 无在线下载源,需两处配合)
- httpx/go-rod 默认在线下载 chromium,但 playwright CDN 对 arm64 返回 400,
  初始化失败后 `HttpxRun` 为 nil,资产测绘整段静默跳过,下游模块收不到数据。
- 处理分两层:
  1. **rod 缓存路径**(`scan-build/dockerfile`):httpx 内嵌 rod(v0.116.2)不读
     `ROD_BROWSER_BIN`,只认缓存路径 `~/.cache/rod/browser/chromium-1124/chrome`
     (arm64 对应 playwright revision 1124,**二进制名必须是 `chrome`**),
     构建时把 apt 安装的 chromium 链接到该路径;
  2. **ROD_BROWSER_BIN**(`docker-compose.arm64.yml`):katana 的 rod 启动器
     通过该环境变量直接使用镜像内 `/usr/bin/chromium`。

### 4. HttpxClose 空指针导致任务结束崩溃(上游 bug,fork 已修)
- `pkg/utils/httpxrun.go` 的 `HttpxClose()` 未判空,httpx 初始化失败时
  每次任务结束必触发 panic,扫描进程被 docker 反复拉起。
- 本 fork 已加判空修复(见 ScopeSentry-Scan 仓库同主题提交)。

### 5. 前端无需单独构建
前端(Vue)产物通过 `go:embed static/*` 打包进服务端二进制
(`cmd/main/main.go:64`),编译服务端时已包含,不存在独立的前端容器。

## 部署结构

```
docker-compose.arm64.yml        # 服务端 + mongodb + redis + 扫描端,单机单文件
├── scope-sentry        Web UI,127.0.0.1:8082,healthy
├── scopesentry-mongodb 127.0.0.1:27017,healthy,mongo:7.0
├── scopesentry-redis   127.0.0.1:6379,healthy,redis:7.0
└── scopesentry-scan    host 网络,Register Success,mem 6g

scan-build/                     # 扫描端镜像构建上下文(不入库,由脚本组装)
├── dockerfile                 # 基于官方 dockerfile,产物为 arm64
├── dist/                      # 扫描端二进制
├── msyh.ttc                   # 中文字体(取自 Scan 仓库)
└── tools/linux/               # 4 个 arm64 工具
```

## 相对官方 single-host-deployment.yml 的安全加固

官方部署文件将 27017/6379 直接发布到 `0.0.0.0`(数据库直接暴露公网),本配置改为:

- mongo / redis / Web UI 全部只绑 `127.0.0.1`(扫描端走 host 网络仍可访问)
- `.env` 强随机密码(官方默认 `mongodb_password` / `redis_password`)
- 容器内存限制:server 2g / scan 6g / mongo 2g / redis 512m
- Web UI 经 nginx 反代并对外,建议叠加 Cloudflare Access 等零信任层

## 版本与目录约定

- 镜像 tag:`scopesentry-server-arm64:<ver>` / `scopesentry-scan-arm64:<ver>`(ver 不带 v 前缀)
- 二进制产物目录沿用 goreleaser 命名:`dist/<项目名>_linux_arm64_v1/`
- 首次初始化密码由程序随机生成(`internal/database/mongodb/initdb.go`),
  写入容器内 `/opt/ScopeSentry/PASSWORD`,改密后可删除该文件
