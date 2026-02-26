#!/bin/bash
#
# 部署状态查看脚本
# 用法: ./status.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEPLOY_DIR"

# 加载 .env 文件
if [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
fi

# 设置默认值
CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}
HAPROXY_HTTP_PORT=${HAPROXY_HTTP_PORT:-80}

HAPROXY_SOCKET="/tmp/admin.sock"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}       蓝绿发布状态                    ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 当前活跃环境
ACTIVE_ENV=$(cat .active_env 2>/dev/null || echo "unknown")
echo -e "当前活跃环境: ${GREEN}${ACTIVE_ENV}${NC}"
echo ""

# 容器状态
echo -e "${YELLOW}容器状态:${NC}"
echo "----------------------------------------"
docker compose ps
echo ""

# 健康检查
echo -e "${YELLOW}健康检查:${NC}"
echo "----------------------------------------"

check_health() {
    local name=$1
    local container=$2

    if docker exec ${container} curl -sf "http://localhost:3000/api/status" > /dev/null 2>&1; then
        echo -e "  ${name}: ${GREEN}健康${NC}"
    else
        echo -e "  ${name}: ${RED}不健康${NC}"
    fi
}

check_health "Blue" "${CONTAINER_BLUE}"
check_health "Green" "${CONTAINER_GREEN}"

# 检查 HAProxy
if curl -sf "http://localhost:${HAPROXY_HTTP_PORT}/api/status" > /dev/null 2>&1; then
    echo -e "  HAProxy (${HAPROXY_HTTP_PORT}): ${GREEN}健康${NC}"
else
    echo -e "  HAProxy (${HAPROXY_HTTP_PORT}): ${RED}不健康${NC}"
fi
echo ""

# 镜像版本
echo -e "${YELLOW}镜像版本:${NC}"
echo "----------------------------------------"
docker inspect ${CONTAINER_BLUE} --format='  Blue:  {{.Config.Image}}' 2>/dev/null || echo "  Blue:  未运行"
docker inspect ${CONTAINER_GREEN} --format='  Green: {{.Config.Image}}' 2>/dev/null || echo "  Green: 未运行"
echo ""

# HAProxy 后端状态
echo -e "${YELLOW}HAProxy 后端状态:${NC}"
echo "----------------------------------------"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
    if docker exec ${CONTAINER_HAPROXY} test -S ${HAPROXY_SOCKET} 2>/dev/null; then
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show servers state' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || echo "  无法获取 HAProxy 状态"
    else
        echo "  HAProxy socket 不可用"
    fi
else
    echo "  HAProxy 容器未运行"
fi
echo ""

# HAProxy 容器状态
echo -e "${YELLOW}HAProxy 容器状态:${NC}"
echo "----------------------------------------"
docker ps --filter "name=${CONTAINER_HAPROXY}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  无法获取 HAProxy 容器状态"
echo ""

# 最近切换历史
if [[ -f "./switch-history.log" ]]; then
    echo -e "${YELLOW}最近切换历史:${NC}"
    echo "----------------------------------------"
    tail -5 ./switch-history.log
fi
