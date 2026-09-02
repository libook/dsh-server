# dsh 自托管：本地建分支、提交这些文件，之后随时合并官方
git add . && git commit -m "docker runtime config (out-of-tree)"
git pull --rebase origin main        # 官方更新后 rebase，零冲突（全新增文件）

# 构建（或直接用 ./build.sh，它会自动拉 submodule 并传 commit hash）：
docker build \
  --build-arg DSH_CLIENT_COMMIT_HASH=$(git rev-parse HEAD) \
  --build-arg DSH_CLIENT_TITLE="My DSH" \
  --build-arg DSH_CLIENT_LOOPBACK_HOSTS="my.example.com" \
  -f Dockerfile -t dsh:local .

echo './dsh-data' >> .git/info/exclude   # 防止把数据目录提交（不碰 .gitignore）

# 占位 hash（最简单，UI 标签显示 0000000）：
docker compose -f compose.yml up -d --build

# 或注入真实 commit（标签更准）：
docker compose -f compose.yml build \
  --build-arg DSH_CLIENT_COMMIT_HASH=$(git rev-parse HEAD) \
  --build-arg DSH_CLIENT_TITLE="My DSH"
docker compose -f compose.yml up -d

# ---------------------------------------------------------------------------
# 容器内 nginx 反代（本镜像的新增行为）
# ---------------------------------------------------------------------------
# 1. dsh 的 web profile 只监听容器内 127.0.0.1:3080，永不直接对外。
# 2. nginx 作为唯一对外入口，监听容器内 3081，把流量反向代理回 dsh：
#      - 重写 Host/Origin 为 127.0.0.1:3080，让 dsh 的 /api 信任篱笆
#        （packages/client/connection/src/api-request-trust.ts）始终把请求
#        判定为本地 127.0.0.1 客户端 → local loop 限制（普通 /api RPC、
#        loopback 专属的配置面方法、/api WebSocket downlink 共用同一篱笆）
#        全部失效。
#      - 支持 WebSocket/SSE 升级与长连接（proxy_buffering off）。
#   具体见 nginx.conf（含明确的安全权衡：任何能访问 3081 的主机都
#   会被当作本机，务必把导出端口放在可信网络）。
# 3. compose 的端口映射 "3080:3081" 即「宿主机 3080 -> 容器内 nginx 3081」。
# 4. 容器以 root 启动（entrypoint 负责 chown 数据卷），dsh 进程经 gosu 降到
#    dsh 用户（uid 1000）。entrypoint 自动为 web profile 追加 --no-open，
#    阻止 dsh 启动时尝试打开浏览器（容器里没有桌面）。

# 单次交互运行（不经 nginx，直接 headless）：
# docker run --rm -it -v "$PWD/dsh-data:/home/dsh/.dsh" dsh:local headless "do a thing"

# ---------------------------------------------------------------------------
# 可配置环境变量
# ---------------------------------------------------------------------------
# 所有自定义值通过环境变量注入，仓库内不含任何个人配置。详见 .env.example。
#
# 构建期（docker build --build-arg / export 后生效）：
#   DSH_CLIENT_TITLE            — UI 标题（默认 "DSH Local Build"）
#   DSH_CLIENT_COMMIT_HASH      — 源 commit hash，7-40 位十六进制（默认 0000000）
#   DSH_CLIENT_LOOPBACK_HOSTS   — 额外 loopback 主机名，逗号分隔（默认空）
#
# 运行期（docker compose up 时通过 .env 或 export 注入）：
#   DSH_SYSLOG_ADDRESS          — syslog UDP 地址（默认空，不转发日志）
#   DSH_HOME_HOST_PATH          — 宿主机数据卷路径（默认 ./dsh-data）

# ---------------------------------------------------------------------------
# 许可证
# ---------------------------------------------------------------------------
# 本项目采用 MIT 许可证，详见 LICENSE 文件。
