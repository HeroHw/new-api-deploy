#!/bin/bash
#
# 灰度环境健康检查脚本
# 用法: ./check-canary-health.sh <target_env>
#
# 返回值:
#   0 - 健康
#   1 - 不健康
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

# 加载 .env 文件
if [ -f "${DEPLOY_DIR}/.env" ]; then
    export $(grep -v '^#' "${DEPLOY_DIR}/.env" | xargs)
fi

TARGET_ENV=${1:-}

# 设置默认值
CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}

HAPROXY_SOCKET="/tmp/admin.sock"

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

if [[ -z "$TARGET_ENV" ]]; then
    log_error "用法: $0 <target_env>"
    exit 1
fi

# 确定容器名
if [[ "$TARGET_ENV" == "blue" ]]; then
    TARGET_CONTAINER="${CONTAINER_BLUE}"
else
    TARGET_CONTAINER="${CONTAINER_GREEN}"
fi

log_info "正在检查 ${TARGET_ENV} 环境健康状态 (容器 ${TARGET_CONTAINER})..."

# 健康检查配置
MAX_RETRIES=3
RETRY_INTERVAL=2
ERROR_THRESHOLD=10  # 错误率阈值 (%)

# 1. 基本健康检查 (单次 HTTP 请求，避免限流)
health_check() {
    local http_code
    http_code=$(docker exec ${TARGET_CONTAINER} curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:3000/api/status")

    log_info "HTTP 状态码: ${http_code}"

    # 2xx 或 429(限流) 都说明服务存活
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]] || [[ "$http_code" == "429" ]]; then
        return 0
    fi
    return 1
}

log_info "执行基本健康检查..."
if ! health_check; then
    log_error "${TARGET_ENV} 基本健康检查失败"
    exit 1
fi
log_info "基本健康检查通过"

# 2. 检查 HAProxy 后端状态
check_haproxy_backend() {
    # 检查 HAProxy 容器是否运行
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
        return 0  # HAProxy 容器不运行时跳过
    fi

    # 检查 socket 是否可用
    if ! docker exec ${CONTAINER_HAPROXY} test -S ${HAPROXY_SOCKET} 2>/dev/null; then
        return 0  # socket 不可用时跳过
    fi

    local status
    status=$(docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show servers state newapi_backend' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null | \
        grep "${TARGET_ENV}" | awk '{print $6}')

    # 状态 2 = UP
    if [[ "$status" == "2" ]]; then
        return 0
    else
        return 1
    fi
}

log_info "检查 HAProxy 后端状态..."
if ! check_haproxy_backend; then
    log_warn "HAProxy 报告 ${TARGET_ENV} 后端状态异常"
fi

# 3. 检查错误率 (从 HAProxy stats 获取)
check_error_rate() {
    # 检查 HAProxy 容器是否运行
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
        return 0  # HAProxy 容器不运行时跳过
    fi

    # 检查 socket 是否可用
    if ! docker exec ${CONTAINER_HAPROXY} test -S ${HAPROXY_SOCKET} 2>/dev/null; then
        return 0  # socket 不可用时跳过
    fi

    local stats
    stats=$(docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show stat' | socat stdio ${HAPROXY_SOCKET}" 2>/dev/null | \
        grep "newapi_backend,${TARGET_ENV}")

    if [[ -z "$stats" ]]; then
        log_warn "无法获取 ${TARGET_ENV} 统计数据"
        return 0
    fi

    # 解析统计数据 (CSV 格式)
    local total_requests error_responses error_rate

    total_requests=$(echo "$stats" | cut -d',' -f8)   # stot
    error_responses=$(echo "$stats" | cut -d',' -f14) # eresp

    if [[ -z "$total_requests" || "$total_requests" == "0" ]]; then
        log_info "暂无请求，跳过错误率检查"
        return 0
    fi

    error_rate=$((error_responses * 100 / total_requests))

    log_info "错误率: ${error_rate}% (阈值: ${ERROR_THRESHOLD}%)"

    if [[ $error_rate -gt $ERROR_THRESHOLD ]]; then
        log_error "错误率 ${error_rate}% 超过阈值 ${ERROR_THRESHOLD}%"
        return 1
    fi

    return 0
}

log_info "检查错误率..."
if ! check_error_rate; then
    log_error "错误率检查失败"
    exit 1
fi

# 4. 检查响应时间
check_response_time() {
    local max_response_time=5000  # 5秒
    local response_time

    response_time=$(docker exec ${TARGET_CONTAINER} curl -sf -o /dev/null -w '%{time_total}' "http://localhost:3000/api/status" 2>/dev/null)

    if [[ -z "$response_time" ]]; then
        log_warn "无法测量响应时间"
        return 0
    fi

    # 转换为毫秒
    response_time_ms=$(echo "$response_time * 1000" | bc 2>/dev/null | cut -d'.' -f1)

    if [[ -z "$response_time_ms" ]]; then
        response_time_ms=0
    fi

    log_info "响应时间: ${response_time_ms}ms (最大: ${max_response_time}ms)"

    if [[ $response_time_ms -gt $max_response_time ]]; then
        log_error "响应时间 ${response_time_ms}ms 超过阈值 ${max_response_time}ms"
        return 1
    fi

    return 0
}

log_info "检查响应时间..."
if ! check_response_time; then
    log_error "响应时间检查失败"
    exit 1
fi

log_info "${TARGET_ENV} 所有健康检查通过"
exit 0
