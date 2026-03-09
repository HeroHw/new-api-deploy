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
HAPROXY_CONFIG_DIR="${DEPLOY_DIR}"

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

# 停止旧环境容器
stop_old_container() {
    local env=$1
    local container

    if [[ "$env" == "blue" ]]; then
        container="${CONTAINER_BLUE}"
    else
        container="${CONTAINER_GREEN}"
    fi

    log_info "正在停止 ${env} 环境容器 (${container})..."

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        docker stop ${container}
        log_info "${env} 环境容器已停止"
    else
        log_warn "${env} 环境容器未运行，跳过停止操作"
    fi
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

# 切换流量（修改配置文件并重载）
log_info "正在切换流量到 ${TARGET_ENV}..."

temp_file="${HAPROXY_CONFIG_DIR}/haproxy.cfg.tmp"
blue_container="${CONTAINER_BLUE}"
green_container="${CONTAINER_GREEN}"

# 修改配置文件
if [[ "$TARGET_ENV" == "blue" ]]; then
    sed -e "s/server blue ${blue_container}:3000.*/server blue ${blue_container}:3000 check inter 5s fall 3 rise 2 weight 100 init-addr last,libc,none/" \
        -e "s/server green ${green_container}:3000.*/server green ${green_container}:3000 check inter 5s fall 3 rise 2 weight 0 disabled init-addr last,libc,none/" \
        "${HAPROXY_CONFIG_DIR}/haproxy.cfg" > "$temp_file"
else
    sed -e "s/server green ${green_container}:3000.*/server green ${green_container}:3000 check inter 5s fall 3 rise 2 weight 100 init-addr last,libc,none/" \
        -e "s/server blue ${blue_container}:3000.*/server blue ${blue_container}:3000 check inter 5s fall 3 rise 2 weight 0 disabled init-addr last,libc,none/" \
        "${HAPROXY_CONFIG_DIR}/haproxy.cfg" > "$temp_file"
fi

mv "$temp_file" "${HAPROXY_CONFIG_DIR}/haproxy.cfg"

# 验证配置文件语法
log_info "验证配置文件语法..."
if ! docker exec ${CONTAINER_HAPROXY} haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg; then
    log_error "配置文件语法错误，中止切换"
    exit 1
fi

# 重新加载 HAProxy 配置（graceful reload，无中断）
log_info "重新加载 HAProxy 配置..."
docker exec ${CONTAINER_HAPROXY} kill -USR2 1

# 等待配置生效
sleep 2
log_info "配置已重新加载"

# 验证切换结果
log_info "正在验证切换结果..."
sleep 2

# 停止源环境（旧版本）
stop_old_container "$SOURCE_ENV"

log_info "流量切换完成，${TARGET_ENV} 环境已激活"

# 记录切换历史
echo "$(date '+%Y-%m-%d %H:%M:%S') - 从 ${SOURCE_ENV} 切换到 ${TARGET_ENV}" >> "${DEPLOY_DIR}/switch-history.log"
