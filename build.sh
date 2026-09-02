#!/bin/sh
# build.sh — 拉取最新 deepseek-harness submodule 并构建 dsh docker 镜像。
#
# 用法：
#   ./build.sh                    # 使用默认标题 "DSH Local Build"
#   ./build.sh "My DSH"           # 自定义标题
#
# 环境变量（可覆盖）：
#   DSH_CLIENT_TITLE            — UI 标题（默认 "DSH Local Build"）
#   DSH_CLIENT_LOOPBACK_HOSTS   — 额外 loopback 主机名，逗号分隔（默认空）
#   DSH_TAG                     — 镜像标签（默认 "dsh:local"）

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── 1. 拉取最新 submodule ──────────────────────────────────────────
echo "==> 更新 deepseek-harness submodule..."
git submodule update --init --recursive
cd deepseek-harness
git fetch origin
git checkout master
git pull --ff-only origin master
cd ..

# ── 2. 获取 submodule commit hash ──────────────────────────────────
DSH_COMMIT="$(git submodule status deepseek-harness | awk '{print $1}')"
echo "==> deepseek-harness @ $DSH_COMMIT"

# ── 3. 构建镜像 ────────────────────────────────────────────────────
TITLE="${DSH_CLIENT_TITLE:-DSH Local Build}"
LOOPBACK_HOSTS="${DSH_CLIENT_LOOPBACK_HOSTS:-}"
TAG="${DSH_TAG:-dsh:local}"

echo "==> 构建镜像 $TAG ..."
docker build \
  --build-arg DSH_CLIENT_COMMIT_HASH="$DSH_COMMIT" \
  --build-arg DSH_CLIENT_TITLE="$TITLE" \
  --build-arg DSH_CLIENT_LOOPBACK_HOSTS="$LOOPBACK_HOSTS" \
  -f Dockerfile \
  -t "$TAG" \
  .

echo "==> 完成: $TAG"
