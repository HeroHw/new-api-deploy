#!/bin/bash
#
# 一键初始化脚本 - 从零开始搭建蓝绿发布环境
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
    echo "    SQL_DSN       - 数据库连接字符串"
    echo "    BLUE_TAG      - Blue 镜像标签"
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
[[ -z "$ACR_REGISTRY" || "$ACR_REGISTRY" == "your-registry.azurecr.io" ]] && MISSING+=("ACR_REGISTRY")
[[ -z "$APP_NAME" ]]   && MISSING+=("APP_NAME")
[[ -z "$SQL_DSN" ]]    && MISSING+=("SQL_DSN")
[[ -z "$BLUE_TAG" ]]   && MISSING+=("BLUE_TAG")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log_error "以下必填项未配置，请编辑 .env 文件："
    for key in "${MISSING[@]}"; do
        echo "  - $key"
    done
    exit 1
fi

# 设置默认值
CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}
NETWORK_NAME=${NETWORK_NAME:-deploy-network}
HAPROXY_HTTP_PORT=${HAPROXY_HTTP_PORT:-80}
HAPROXY_STATS_PORT=${HAPROXY_STATS_PORT:-8404}
HAPROXY_SOCKET="/tmp/admin.sock"

log_ok ".env 配置加载完成（ACR: ${ACR_REGISTRY}, APP: ${APP_NAME}）"

# ─── 创建 Docker 网络 ─────────────────────────────────────────────────────────

log_step "创建 Docker 网络..."

if docker network inspect "${NETWORK_NAME}" &>/dev/null; then
    log_info "网络 ${NETWORK_NAME} 已存在，跳过"
else
    docker network create "${NETWORK_NAME}"
    log_ok "网络 ${NETWORK_NAME} 已创建"
fi

# ─── 创建数据目录 ─────────────────────────────────────────────────────────────

log_step "创建数据和日志目录..."

mkdir -p data-blue data-green logs-blue logs-green
log_ok "目录已就绪"

# ─── 生成 HAProxy 配置 ────────────────────────────────────────────────────────

log_step "生成 HAProxy 配置（初始激活环境: blue）..."

ACTIVE_ENV=blue bash "${SCRIPT_DIR}/generate-haproxy-config.sh"
echo "blue" > .active_env

log_ok "haproxy.cfg 已生成"

# ─── 构建 HAProxy 镜像 ────────────────────────────────────────────────────────

log_step "构建 HAProxy 镜像（含 socat）..."

docker compose -f docker-compose-haproxy.yml build --quiet
log_ok "HAProxy 镜像构建完成"

# ─── 拉取应用镜像 ─────────────────────────────────────────────────────────────

log_step "拉取应用镜像..."

IMAGE="${ACR_REGISTRY}/${APP_NAME}:${BLUE_TAG}"
log_info "拉取: ${IMAGE}"

if ! docker pull "${IMAGE}"; then
    log_warn "镜像拉取失败，若使用私有仓库请先登录："
    echo "  docker login ${ACR_REGISTRY}"
    exit 1
fi

log_ok "镜像拉取完成"

# ─── 启动 Blue 应用容器 ───────────────────────────────────────────────────────

log_step "启动 Blue 应用容器..."

# 仅启动 blue，green 在首次部署时再启动
docker compose up -d "${CONTAINER_BLUE}"

# 等待 blue 健康
log_info "等待 Blue 容器健康检查通过..."
for i in {1..60}; do
    if docker exec "${CONTAINER_BLUE}" curl -sf "http://localhost:3000/api/status" &>/dev/null; then
        log_ok "Blue 容器已就绪"
        break
    fi

    if [[ $i -eq 60 ]]; then
        log_error "Blue 容器启动超时，查看日志："
        docker logs "${CONTAINER_BLUE}" 2>&1 | tail -30
        exit 1
    fi

    if [[ $((i % 10)) -eq 0 ]]; then
        log_info "等待 Blue 就绪... (${i}/60)"
    fi
    sleep 1
done

# ─── 启动 HAProxy ─────────────────────────────────────────────────────────────

log_step "启动 HAProxy..."

docker compose -f docker-compose-haproxy.yml up -d

# 等待 HAProxy Runtime API socket 就绪
log_info "等待 HAProxy Runtime API 就绪..."
for i in {1..30}; do
    if docker exec "${CONTAINER_HAPROXY}" test -S "${HAPROXY_SOCKET}" 2>/dev/null; then
        if docker exec "${CONTAINER_HAPROXY}" sh -c "echo 'show info' | socat stdio ${HAPROXY_SOCKET}" &>/dev/null; then
            log_ok "HAProxy Runtime API 已就绪"
            break
        fi
    fi

    if [[ $i -eq 30 ]]; then
        log_error "HAProxy 启动超时，查看日志："
        docker logs "${CONTAINER_HAPROXY}" 2>&1 | tail -20
        exit 1
    fi

    if [[ $((i % 5)) -eq 0 ]]; then
        log_info "等待 HAProxy 就绪... (${i}/30)"
    fi
    sleep 1
done

# ─── 端到端验证 ───────────────────────────────────────────────────────────────

log_step "端到端链路验证..."

sleep 2

if curl -sf "http://localhost:${HAPROXY_HTTP_PORT}/api/status" &>/dev/null; then
    log_ok "链路验证通过：http://localhost:${HAPROXY_HTTP_PORT}/api/status 正常响应"
else
    log_warn "HAProxy 健康检查未通过，可能应用尚未完全启动，请稍后检查"
fi

# ─── 完成 ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}========================================${NC}"
echo -e "${BOLD}${GREEN}   初始化完成！${NC}"
echo -e "${BOLD}${GREEN}========================================${NC}"
echo ""
echo -e "  应用入口:    ${BOLD}http://localhost:${HAPROXY_HTTP_PORT}${NC}"
echo -e "  HAProxy 统计: ${BOLD}http://localhost:${HAPROXY_STATS_PORT}${NC}"
echo -e "  当前活跃环境: ${BOLD}blue${NC}"
echo ""
echo -e "  常用命令:"
echo "    查看状态:   bash scripts/status.sh"
echo "    切换流量:   bash scripts/switch-traffic.sh <blue|green>"
echo ""

# 设置脚本执行权限（供后续使用）
chmod +x scripts/*.sh
