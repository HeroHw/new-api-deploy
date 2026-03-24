#!/bin/bash
#
# 一键初始化脚本 - 启动单服务环境
# 用法: ./scripts/init.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEPLOY_DIR"

# 颜色输出
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

# ─── 前置依赖检查 ─────────────────────────────────────────────────────────────

log_step "检查前置依赖..."

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        log_error "未找到命令: $1，请先安装"
        exit 1
    fi
    log_info "$1 已安装"
}

check_cmd docker
check_cmd curl

if ! docker info &>/dev/null; then
    log_error "Docker 未运行，请先启动 Docker"
    exit 1
fi

if ! docker compose version &>/dev/null; then
    log_error "未找到 docker compose（V2），请升级 Docker Desktop 或安装 docker-compose-plugin"
    exit 1
fi

log_ok "依赖检查通过"

# ─── 配置文件 ─────────────────────────────────────────────────────────────────

log_step "配置 .env 文件..."

if [[ ! -f ".env" ]]; then
    log_error ".env 文件不存在，请创建并填写配置后重新运行"
    echo ""
    echo "  必填项:"
    echo "    ACR_REGISTRY  - 镜像仓库地址（如 registry.example.com）"
    echo "    APP_NAME      - 应用名称"
    echo "    IMAGE_TAG     - 镜像标签（如 v20260304）"
    exit 1
fi

# 加载环境变量
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
done < .env

# 校验必填项
MISSING=()
[[ -z "$ACR_REGISTRY" ]] && MISSING+=("ACR_REGISTRY")
[[ -z "$APP_NAME" ]]     && MISSING+=("APP_NAME")
[[ -z "$IMAGE_TAG" ]]    && MISSING+=("IMAGE_TAG")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log_error "以下必填项未配置，请编辑 .env 文件："
    for key in "${MISSING[@]}"; do
        echo "  - $key"
    done
    exit 1
fi

CONTAINER_NAME=${CONTAINER_NAME:-app}
NETWORK_NAME=${NETWORK_NAME:-deploy-network}
APP_PORT=${APP_PORT:-3000}

log_ok ".env 配置加载完成（ACR: ${ACR_REGISTRY}, APP: ${APP_NAME}, TAG: ${IMAGE_TAG}）"

# ─── 创建 Docker 网络 ─────────────────────────────────────────────────────────

log_step "创建 Docker 网络..."

if docker network inspect "${NETWORK_NAME}" &>/dev/null; then
    log_info "网络 ${NETWORK_NAME} 已存在，跳过"
else
    docker network create "${NETWORK_NAME}"
    log_ok "网络 ${NETWORK_NAME} 已创建"
fi

# ─── 拉取应用镜像 ─────────────────────────────────────────────────────────────

log_step "拉取应用镜像..."

IMAGE="${ACR_REGISTRY}/${APP_NAME}:${IMAGE_TAG}"
log_info "拉取: ${IMAGE}"

if ! docker pull "${IMAGE}"; then
    log_warn "镜像拉取失败，若使用私有仓库请先登录："
    echo "  docker login ${ACR_REGISTRY}"
    exit 1
fi

log_ok "镜像拉取完成"

# ─── 启动应用容器 ─────────────────────────────────────────────────────────────

log_step "启动应用容器..."

docker compose up -d app

# 等待容器健康
log_info "等待容器健康检查通过（最多 60s）..."
for i in {1..60}; do
    if docker exec "${CONTAINER_NAME}" curl -sf "http://localhost:3000/api/status" &>/dev/null; then
        log_ok "容器已就绪"
        break
    fi

    if [[ $i -eq 60 ]]; then
        log_error "容器启动超时，查看日志："
        docker logs "${CONTAINER_NAME}" 2>&1 | tail -30
        exit 1
    fi

    if [[ $((i % 10)) -eq 0 ]]; then
        log_info "等待就绪... (${i}/60)"
    fi
    sleep 1
done

# ─── 端到端验证 ───────────────────────────────────────────────────────────────

log_step "端到端链路验证..."

sleep 1

if curl -sf "http://localhost:${APP_PORT}/api/status" &>/dev/null; then
    log_ok "链路验证通过：http://localhost:${APP_PORT}/api/status 正常响应"
else
    log_warn "健康检查未通过，可能应用尚未完全启动，请稍后检查"
fi

# ─── 完成 ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}========================================${NC}"
echo -e "${BOLD}${GREEN}   初始化完成！${NC}"
echo -e "${BOLD}${GREEN}========================================${NC}"
echo ""
echo -e "  应用入口:   ${BOLD}http://localhost:${APP_PORT}${NC}"
echo -e "  镜像版本:   ${BOLD}${IMAGE_TAG}${NC}"
echo ""
echo -e "  常用命令:"
echo "    查看状态:   bash scripts/status.sh"
echo "    回滚版本:   bash scripts/rollback.sh <image_tag>"
echo "    停止服务:   bash scripts/down.sh"
echo ""

chmod +x scripts/*.sh
