#!/bin/bash
#
# 回滚到指定镜像版本
# 用法: ./scripts/rollback.sh <image_tag>
# 例如: ./scripts/rollback.sh v20260301
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEPLOY_DIR"

# ─── 颜色输出 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}${BLUE}▶ $1${NC}"; }
log_ok()    { echo -e "${GREEN}✅ $1${NC}"; }

TARGET_TAG=${1:-}

if [[ -z "$TARGET_TAG" ]]; then
    log_error "用法: $0 <image_tag>"
    log_error "示例: $0 v20260301"
    exit 1
fi

# ─── 加载 .env ────────────────────────────────────────────────────────────────
if [[ -f ".env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    done < .env
fi

CONTAINER_NAME=${CONTAINER_NAME:-app}
CURRENT_TAG=${IMAGE_TAG:-unknown}

log_step "回滚: ${CURRENT_TAG} → ${TARGET_TAG}"

# ─── 更新 .env 中的 IMAGE_TAG ─────────────────────────────────────────────────
log_step "更新 IMAGE_TAG..."

if grep -q "^IMAGE_TAG=" .env; then
    sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${TARGET_TAG}|" .env
else
    echo "IMAGE_TAG=${TARGET_TAG}" >> .env
fi

export IMAGE_TAG="${TARGET_TAG}"
log_ok "IMAGE_TAG 已更新为 ${TARGET_TAG}"

# ─── 拉取目标镜像 ─────────────────────────────────────────────────────────────
log_step "拉取目标镜像..."

if ! docker compose pull app; then
    log_error "镜像拉取失败，请确认镜像标签是否正确: ${ACR_REGISTRY}/${APP_NAME}:${TARGET_TAG}"
    # 恢复原来的 TAG
    sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${CURRENT_TAG}|" .env
    exit 1
fi

log_ok "镜像拉取完成"

# ─── 重启服务 ─────────────────────────────────────────────────────────────────
log_step "重启服务..."

docker compose up -d --force-recreate app

# ─── 等待健康 ─────────────────────────────────────────────────────────────────
log_step "等待服务健康检查（最多 60s）..."

for i in {1..60}; do
    if docker exec "${CONTAINER_NAME}" curl -sf "http://localhost:3000/api/status" &>/dev/null; then
        log_ok "服务已就绪"
        break
    fi

    if [[ $i -eq 60 ]]; then
        log_error "服务启动超时，查看日志："
        docker logs "${CONTAINER_NAME}" 2>&1 | tail -20
        exit 1
    fi

    if [[ $((i % 10)) -eq 0 ]]; then
        log_info "等待中... (${i}/60)"
    fi
    sleep 1
done

# ─── 完成 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}========================================${NC}"
echo -e "${BOLD}${GREEN}   回滚完成！${NC}"
echo -e "${BOLD}${GREEN}========================================${NC}"
echo ""
echo -e "  当前版本: ${BOLD}${TARGET_TAG}${NC}"
echo ""
echo -e "  查看状态: bash scripts/status.sh"
echo ""
