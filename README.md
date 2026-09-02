# dsh 自托管指南

本仓库是 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（简称 dsh）的**自托管运行时镜像**，基于 Docker + Docker Compose。

> **快速开始**：`cp .env.example .env` → 编辑 → `./build.sh` → `docker compose -f compose.yml up -d --build`

---

## 目录

- [快速开始](#快速开始)
- [构建镜像](#构建镜像)
- [启动服务](#启动服务)
- [单次交互运行](#单次交互运行)
- [环境变量](#环境变量)
- [nginx 反代说明](#nginx-反代说明)
- [数据持久化](#数据持久化)
- [许可证](#许可证)

---

## 快速开始

```sh
# 1. 复制环境变量模板并按需修改
cp .env.example .env

# 2. 构建镜像（自动拉取 submodule、注入 commit hash）
./build.sh

# 3. 启动 Web 服务
docker compose -f compose.yml up -d --build
```

打开浏览器访问 `http://<宿主机>:3080` 即可看到 dsh Web UI。

---

## 构建镜像

### 方式一：使用 `build.sh`（推荐）

`build.sh` 会自动拉取 `deepseek-harness` submodule 的最新 commit，并将其 hash 注入镜像标签：

```sh
# 默认标题 "DSH Local Build"
./build.sh

# 自定义标题
./build.sh "My DSH"

# 自定义 loopback 主机名（逗号分隔）
DSH_CLIENT_LOOPBACK_HOSTS="my.example.com" ./build.sh

# 自定义镜像标签
DSH_TAG="dsh:mytag" ./build.sh
```

### 方式二：直接 `docker build`

```sh
docker build \
  --build-arg DSH_CLIENT_COMMIT_HASH=$(git rev-parse HEAD) \
  --build-arg DSH_CLIENT_TITLE="My DSH" \
  --build-arg DSH_CLIENT_LOOPBACK_HOSTS="my.example.com" \
  -f Dockerfile -t dsh:local .
```

> **占位 hash**：若不传 `DSH_CLIENT_COMMIT_HASH`，UI 标签显示 `0000000`，不影响任何行为。

### 合并官方更新

本仓库在 `main` 分支上保留了 out-of-tree 的 Docker 相关文件。官方 submodule 更新后，直接运行 `./build.sh` 即可——它会自动拉取 `deepseek-harness` 的最新 commit 并重新构建。

由于 out-of-tree 文件是**新增**的，rebase 时不会产生冲突。

---

## 启动服务

```sh
# 构建并启动（后台）
docker compose -f compose.yml up -d --build

# 停止并删除容器
docker compose -f compose.yml down

# 查看日志
docker compose -f compose.yml logs -f
```

### compose.yml 关键配置

| 配置项 | 说明 |
|--------|------|
| 端口映射 `3080:3081` | 宿主机 3080 → 容器内 nginx 3081 |
| 数据卷 `./dsh-data:/home/dsh` | 持久化配置、凭证、插件 |
| `restart: unless-stopped` | 容器崩溃自动重启 |
| 默认 seccomp + Landlock | 无 `cap_add`，无 `--security-opt` |

---

## 单次交互运行

不经 nginx，直接以 headless 模式运行一次性命令：

```sh
docker run --rm -it -v "$PWD/dsh-data:/home/dsh/.dsh" dsh:local headless "do a thing"
```

---

## 环境变量

所有自定义值通过环境变量注入，仓库内不含任何个人配置。

### 构建期变量（需重建镜像）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DSH_CLIENT_TITLE` | `"DSH Local Build"` | UI 标题 |
| `DSH_CLIENT_COMMIT_HASH` | `0000000` | 源 commit hash（7–40 位十六进制） |
| `DSH_CLIENT_LOOPBACK_HOSTS` | 空 | 额外 loopback 主机名，逗号分隔 |

### 运行期变量（无需重建）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DSH_SYSLOG_ADDRESS` | 空 | syslog UDP 地址（空 = 不转发日志） |
| `DSH_HOME_HOST_PATH` | `./dsh-data` | 宿主机数据卷路径 |

> 详细说明见 [`.env.example`](.env.example)。

---

## nginx 反代说明

### 为什么需要 nginx？

dsh 的 web profile **只监听容器内 `127.0.0.1:3080`**，永不直接对外。nginx 作为唯一对外入口，监听容器内 `3081`，将流量反向代理回 dsh。

### Host/Origin 重写

nginx 将所有请求的 `Host` 和 `Origin` 重写为 `127.0.0.1:3080`，使 dsh 的 `/api` 信任篱笆始终将请求判定为**本地 loopback 客户端**。这使得以下功能在非 loopback 部署下仍能正常工作：

- 普通 `/api` RPC
- loopback 专属的配置面方法
- `/api` WebSocket 下行链路

### 安全权衡（有意为之）

此设计**禁用了** dsh 的 DNS-rebinding 和跨站防护，任何能访问 3081 端口的主机都会被当作本机。请将导出端口放在可信网络内。

### WebSocket / 长连接

nginx 关闭了 `proxy_buffering`，并配置了 1 小时的读写超时，支持 WebSocket/SSE 升级与长连接。

---

## 数据持久化

`$DSH_HOME`（容器内 `/home/dsh/.dsh`）bind mount 到宿主机的 `./dsh-data` 目录，以下数据在容器重建、镜像更新后依然保留：

- 配置文件
- API 凭证（文件权限 0600 / 目录 0700）
- 会话状态
- 已安装插件

> ⚠️ `./dsh-data` 视为敏感目录，建议备份并限制宿主机访问权限。

### 版本漂移自动修复

容器启动时，若检测到 dsh 版本发生变化，entrypoint 会自动对每个已持久化 profile 的插件依赖重新执行 `pnpm install`，确保插件与新版本核心兼容。

---

## 许可证

本项目采用 [MIT 许可证](LICENSE)，详见 LICENSE 文件。