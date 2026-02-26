#!/bin/bash
#
# 快速回滚脚本
# 用法: ./rollback.sh
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

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 获取当前活跃环境
CURRENT_ENV=$(cat .active_env 2>/dev/null || echo "blue")

# 目标环境是非活跃的那个
if [[ "$CURRENT_ENV" == "blue" ]]; then
    TARGET_ENV="green"
else
    TARGET_ENV="blue"
fi

log_info "当前活跃环境: ${CURRENT_ENV}"
log_info "回滚目标环境: ${TARGET_ENV}"

# 检查目标环境是否可用
if [[ "$TARGET_ENV" == "blue" ]]; then
    TARGET_CONTAINER="${CONTAINER_BLUE}"
else
    TARGET_CONTAINER="${CONTAINER_GREEN}"
fi

if ! docker exec ${TARGET_CONTAINER} curl -sf "http://localhost:3000/api/status" > /dev/null 2>&1; then
    log_error "${TARGET_ENV} 环境不健康，无法回滚"
    log_error "请检查 ${TARGET_ENV} 容器状态"
    exit 1
fi

# 执行切换
./scripts/switch-traffic.sh "$TARGET_ENV"

# 更新活跃环境记录
echo "$TARGET_ENV" > .active_env

log_info "回滚完成! ${TARGET_ENV} 环境已激活"
log_info "原环境 (${CURRENT_ENV}) 仍在运行，可用于调试"
