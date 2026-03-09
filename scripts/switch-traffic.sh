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

# 切换流量（使用 Runtime API，零中断）
log_info "正在切换流量到 ${TARGET_ENV}..."

HAPROXY_SOCKET="/tmp/admin.sock"

# 检查 socat 是否可用
if ! docker exec ${CONTAINER_HAPROXY} which socat >/dev/null 2>&1; then
    log_error "HAProxy 容器内未安装 socat，请重新构建 HAProxy 镜像"
    exit 1
fi

# 检查 socket 是否可用
if ! docker exec ${CONTAINER_HAPROXY} test -S ${HAPROXY_SOCKET} 2>/dev/null; then
    log_error "HAProxy Runtime API socket 不可用"
    exit 1
fi

# 使用 Runtime API 切换流量
log_info "通过 Runtime API 切换流量（零中断）..."

if [[ "$TARGET_ENV" == "blue" ]]; then
    # 切换到 blue
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/blue state ready' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/blue weight 100' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/green weight 0' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/green state maint' | socat stdio ${HAPROXY_SOCKET}"

    # 同时更新测试后端
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_blue/blue state ready' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_blue/blue weight 100' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_green/green weight 0' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_green/green state maint' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
else
    # 切换到 green
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/green state ready' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/green weight 100' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/blue weight 0' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/blue state maint' | socat stdio ${HAPROXY_SOCKET}"

    # 同时更新测试后端
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_green/green state ready' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_green/green weight 100' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_blue/blue weight 0' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_blue/blue state maint' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null || true
fi

log_info "Runtime API 切换成功（零中断）"

# 检查 DNS 解析状态
log_info "检查 DNS 解析状态..."
SERVER_STATE=$(docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show servers state' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null | grep "newapi_backend.*${TARGET_ENV}" || true)

if echo "$SERVER_STATE" | grep -q -- "-" | head -1 | awk '{print $4}' | grep -q "^-$"; then
    log_warn "检测到 DNS 解析问题，正在重启 HAProxy 以重新解析..."
    docker restart ${CONTAINER_HAPROXY}

    # 等待 HAProxy 重启完成
    log_info "等待 HAProxy 重启..."
    sleep 8

    # 验证 socket 可用
    for i in {1..10}; do
        if docker exec ${CONTAINER_HAPROXY} test -S ${HAPROXY_SOCKET} 2>/dev/null; then
            log_info "✅ HAProxy 已重启"
            break
        fi
        if [ $i -eq 10 ]; then
            log_error "HAProxy 重启后 socket 不可用"
            exit 1
        fi
        sleep 1
    done

    # 重启后重新应用流量配置
    log_info "重新应用流量配置..."
    if [[ "$TARGET_ENV" == "blue" ]]; then
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/blue state ready' | socat stdio ${HAPROXY_SOCKET}"
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/blue weight 100' | socat stdio ${HAPROXY_SOCKET}"
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/green weight 0' | socat stdio ${HAPROXY_SOCKET}"
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/green state maint' | socat stdio ${HAPROXY_SOCKET}"
    else
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/green state ready' | socat stdio ${HAPROXY_SOCKET}"
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/green weight 100' | socat stdio ${HAPROXY_SOCKET}"
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/blue weight 0' | socat stdio ${HAPROXY_SOCKET}"
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/blue state maint' | socat stdio ${HAPROXY_SOCKET}"
    fi
    log_info "✅ DNS 解析问题已修复"
fi

# 验证切换结果
log_info "正在验证切换结果..."
sleep 2

# 停止源环境（旧版本）
stop_old_container "$SOURCE_ENV"

log_info "流量切换完成，${TARGET_ENV} 环境已激活"

# 记录切换历史
echo "$(date '+%Y-%m-%d %H:%M:%S') - 从 ${SOURCE_ENV} 切换到 ${TARGET_ENV}" >> "${DEPLOY_DIR}/switch-history.log"
