#!/bin/bash
#
# 设置灰度流量权重脚本
# 用法: ./set-canary-weight.sh <current_env> <target_env> <percentage>
# 例如: ./set-canary-weight.sh blue green 10  # 10% 流量到 green
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

# 加载 .env 文件
if [ -f "${DEPLOY_DIR}/.env" ]; then
    export $(grep -v '^#' "${DEPLOY_DIR}/.env" | xargs)
fi

CURRENT_ENV=${1:-}
TARGET_ENV=${2:-}
PERCENTAGE=${3:-}

# 设置默认值
CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}

HAPROXY_SOCKET="/tmp/admin.sock"
HAPROXY_CONFIG_DIR="${DEPLOY_DIR}"

# backend 名称前缀 (与 haproxy.cfg 中保持一致)
BACKEND_PREFIX="newapi"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 验证参数
if [[ -z "$CURRENT_ENV" || -z "$TARGET_ENV" || -z "$PERCENTAGE" ]]; then
    log_error "用法: $0 <current_env> <target_env> <percentage>"
    log_error "示例: $0 blue green 10"
    exit 1
fi

if [[ ! "$PERCENTAGE" =~ ^[0-9]+$ ]] || [[ "$PERCENTAGE" -lt 0 ]] || [[ "$PERCENTAGE" -gt 100 ]]; then
    log_error "百分比必须是 0-100 之间的数字"
    exit 1
fi

# 检查 HAProxy 容器是否运行
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
    log_error "HAProxy 容器未运行，请先启动容器"
    exit 1
fi

# 计算权重
CURRENT_WEIGHT=$((100 - PERCENTAGE))
TARGET_WEIGHT=$PERCENTAGE

log_info "设置流量分配: ${CURRENT_ENV}=${CURRENT_WEIGHT}%, ${TARGET_ENV}=${TARGET_WEIGHT}%"

# 使用 HAProxy Runtime API 设置权重
set_weight_via_api() {
    log_info "通过 HAProxy Runtime API 配置..."

    # 确保两个服务器都是 ready 状态
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server ${BACKEND_PREFIX}_backend/${CURRENT_ENV} state ready' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server ${BACKEND_PREFIX}_backend/${TARGET_ENV} state ready' | socat stdio ${HAPROXY_SOCKET}"

    # 设置权重
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server ${BACKEND_PREFIX}_backend/${CURRENT_ENV} weight ${CURRENT_WEIGHT}' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server ${BACKEND_PREFIX}_backend/${TARGET_ENV} weight ${TARGET_WEIGHT}' | socat stdio ${HAPROXY_SOCKET}"

    log_info "权重配置成功"
}

# 备选方案：通过配置文件
set_weight_via_config() {
    log_info "通过配置重载方式配置..."

    local temp_file="${HAPROXY_CONFIG_DIR}/haproxy.cfg.tmp"
    local blue_container="${CONTAINER_BLUE}"
    local green_container="${CONTAINER_GREEN}"

    # 使用 sed 更新权重
    sed -e "s/server ${CURRENT_ENV} ${blue_container}:3000.* weight [0-9]*/server ${CURRENT_ENV} ${blue_container}:3000 check inter 5s fall 3 rise 2 weight ${CURRENT_WEIGHT}/" \
        -e "s/server ${TARGET_ENV} ${green_container}:3000.* weight [0-9]*/server ${TARGET_ENV} ${green_container}:3000 check inter 5s fall 3 rise 2 weight ${TARGET_WEIGHT}/" \
        "${HAPROXY_CONFIG_DIR}/haproxy.cfg" > "$temp_file"

    # 移除 disabled 标记（如果存在）
    sed -i 's/ disabled$//' "$temp_file"

    mv "$temp_file" "${HAPROXY_CONFIG_DIR}/haproxy.cfg"

    # 重新加载 HAProxy
    docker exec ${CONTAINER_HAPROXY} haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg && \
    docker exec ${CONTAINER_HAPROXY} kill -USR2 1

    log_info "配置重载成功"
}

# 尝试使用 Runtime API
if docker exec ${CONTAINER_HAPROXY} test -S ${HAPROXY_SOCKET} 2>/dev/null; then
    set_weight_via_api
else
    log_warn "HAProxy socket 不可用，使用配置重载方式"
    set_weight_via_config
fi

# 验证配置
log_info "正在验证配置..."
sleep 1

docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show servers state ${BACKEND_PREFIX}_backend' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || \
    log_warn "无法通过 socket 验证，请检查 HAProxy 统计页面"

# 记录灰度历史
echo "$(date '+%Y-%m-%d %H:%M:%S') - 灰度: ${CURRENT_ENV}=${CURRENT_WEIGHT}%, ${TARGET_ENV}=${TARGET_WEIGHT}%" >> "${DEPLOY_DIR}/canary-history.log"

log_info "流量分配已配置: ${CURRENT_ENV}=${CURRENT_WEIGHT}%, ${TARGET_ENV}=${TARGET_WEIGHT}%"
