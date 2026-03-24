#!/bin/bash
#
# 部署状态查看脚本
# 用法: ./scripts/status.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEPLOY_DIR"

# 加载 .env 文件
if [ -f ".env" ]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    done < .env
fi

CONTAINER_NAME=${CONTAINER_NAME:-app}
APP_PORT=${APP_PORT:-3000}

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}         服务状态                      ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 容器状态
echo -e "${YELLOW}容器状态:${NC}"
echo "----------------------------------------"
docker compose ps
echo ""

# 健康检查
echo -e "${YELLOW}健康检查:${NC}"
echo "----------------------------------------"
if docker exec "${CONTAINER_NAME}" curl -sf "http://localhost:3000/api/status" > /dev/null 2>&1; then
    echo -e "  容器内部: ${GREEN}健康${NC}"
else
    echo -e "  容器内部: ${RED}不健康${NC}"
fi

if curl -sf "http://localhost:${APP_PORT}/api/status" > /dev/null 2>&1; then
    echo -e "  外部端口 (${APP_PORT}): ${GREEN}健康${NC}"
else
    echo -e "  外部端口 (${APP_PORT}): ${RED}不健康${NC}"
fi
echo ""

# 镜像版本
echo -e "${YELLOW}镜像版本:${NC}"
echo "----------------------------------------"
docker inspect "${CONTAINER_NAME}" --format='  当前镜像: {{.Config.Image}}' 2>/dev/null || echo "  容器未运行"
echo ""
