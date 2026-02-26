#!/bin/bash
#
# 蓝绿发布流量切换脚本
# 用法: ./switch-traffic.sh <blue|green>
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

# 加载 .env 文件
if [ -f "${DEPLOY_DIR}/.env" ]; then
    export $(grep -v '^#' "${DEPLOY_DIR}/.env" | xargs)
fi

# 设置默认值
CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}

TARGET_ENV=${1:-}
HAPROXY_SOCKET="/run/haproxy/admin.sock"
HAPROXY_CONFIG_DIR="${DEPLOY_DIR}/haproxy"

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
if [[ -z "$TARGET_ENV" ]]; then
    log_error "用法: $0 <blue|green>"
    exit 1
fi

if [[ "$TARGET_ENV" != "blue" && "$TARGET_ENV" != "green" ]]; then
    log_error "无效的环境: $TARGET_ENV，必须是 'blue' 或 'green'"
    exit 1
fi

# 确定源环境
if [[ "$TARGET_ENV" == "blue" ]]; then
    SOURCE_ENV="green"
else
    SOURCE_ENV="blue"
fi

log_info "正在将流量从 ${SOURCE_ENV} 切换到 ${TARGET_ENV}"

# 检查目标环境健康状态
check_health() {
    local env=$1
    local container

    if [[ "$env" == "blue" ]]; then
        container="${CONTAINER_BLUE}"
    else
        container="${CONTAINER_GREEN}"
    fi

    if docker exec ${container} curl -sf "http://localhost:3000/api/status" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

log_info "正在检查 ${TARGET_ENV} 环境健康状态..."
if ! check_health "$TARGET_ENV"; then
    log_error "${TARGET_ENV} 环境不健康，中止切换"
    exit 1
fi
log_info "${TARGET_ENV} 环境健康检查通过"

# 检查 HAProxy 容器是否运行
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
    log_error "HAProxy 容器未运行，请先启动容器"
    exit 1
fi

# 使用 HAProxy Runtime API 切换流量
switch_via_runtime_api() {
    log_info "通过 HAProxy Runtime API 切换流量..."

    # 启用目标服务器
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server ${BACKEND_PREFIX}_backend/${TARGET_ENV} state ready' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server ${BACKEND_PREFIX}_backend/${TARGET_ENV} weight 100' | socat stdio ${HAPROXY_SOCKET}"

    # 禁用源服务器
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server ${BACKEND_PREFIX}_backend/${SOURCE_ENV} weight 0' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server ${BACKEND_PREFIX}_backend/${SOURCE_ENV} state maint' | socat stdio ${HAPROXY_SOCKET}"

    log_info "通过 Runtime API 切换成功"
}

# 备选方案：通过重新加载配置切换
switch_via_config_reload() {
    log_info "通过配置重载切换流量..."

    local temp_file="${HAPROXY_CONFIG_DIR}/haproxy.cfg.tmp"
    local blue_container="${CONTAINER_BLUE}"
    local green_container="${CONTAINER_GREEN}"

    # 修改配置文件 - 使用宽松匹配，兼容灰度发布后的任意权重状态
    if [[ "$TARGET_ENV" == "blue" ]]; then
        sed -e "s/server blue ${blue_container}:3000.*/server blue ${blue_container}:3000 check inter 5s fall 3 rise 2 weight 100/" \
            -e "s/server green ${green_container}:3000.*/server green ${green_container}:3000 check inter 5s fall 3 rise 2 weight 0 disabled/" \
            "${HAPROXY_CONFIG_DIR}/haproxy.cfg" > "$temp_file"
    else
        sed -e "s/server green ${green_container}:3000.*/server green ${green_container}:3000 check inter 5s fall 3 rise 2 weight 100/" \
            -e "s/server blue ${blue_container}:3000.*/server blue ${blue_container}:3000 check inter 5s fall 3 rise 2 weight 0 disabled/" \
            "${HAPROXY_CONFIG_DIR}/haproxy.cfg" > "$temp_file"
    fi

    mv "$temp_file" "${HAPROXY_CONFIG_DIR}/haproxy.cfg"

    # 重新加载 HAProxy 容器
    docker exec ${CONTAINER_HAPROXY} haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg && \
    docker exec ${CONTAINER_HAPROXY} kill -USR2 1

    log_info "通过配置重载切换成功"
}

# 尝试使用 Runtime API，失败则使用配置重载
if docker exec ${CONTAINER_HAPROXY} test -S ${HAPROXY_SOCKET} 2>/dev/null; then
    switch_via_runtime_api
else
    log_warn "HAProxy socket 不可用，使用配置重载方式"
    switch_via_config_reload
fi

# 验证切换结果
log_info "正在验证切换结果..."
sleep 2

# 检查 HAProxy stats
docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show servers state' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true

log_info "流量切换完成，${TARGET_ENV} 环境已激活"

# 记录切换历史
echo "$(date '+%Y-%m-%d %H:%M:%S') - 从 ${SOURCE_ENV} 切换到 ${TARGET_ENV} (100%)" >> "${DEPLOY_DIR}/switch-history.log"

# 更新灰度后端指向下次部署的目标环境
update_canary_backend() {
    log_info "更新灰度后端指向 ${SOURCE_ENV} (下次部署目标)..."

    local target_container="app-${SOURCE_ENV}"
    docker exec ${HAPROXY_CONTAINER} sh -c "echo 'set server ${BACKEND_PREFIX}_canary/canary addr ${target_container} port 3000' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
}

update_canary_backend 2>/dev/null || true
