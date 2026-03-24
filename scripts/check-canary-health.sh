#!/bin/bash
#
# 服务健康检查脚本
# 用法: ./scripts/check-canary-health.sh
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
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    done < "${DEPLOY_DIR}/.env"
fi

CONTAINER_NAME=${CONTAINER_NAME:-app}

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

log_info "正在检查服务健康状态 (容器: ${CONTAINER_NAME})..."

# 1. 基本健康检查
log_info "执行基本健康检查..."
http_code=$(docker exec "${CONTAINER_NAME}" curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:3000/api/status")

log_info "HTTP 状态码: ${http_code}"

# 2xx 或 429(限流) 都说明服务存活
if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]] && [[ "$http_code" != "429" ]]; then
    log_error "基本健康检查失败，HTTP 状态码: ${http_code}"
    exit 1
fi
log_info "基本健康检查通过"

# 2. 检查响应时间
log_info "检查响应时间..."
max_response_time=5000  # 5秒

response_time=$(docker exec "${CONTAINER_NAME}" curl -sf -o /dev/null -w '%{time_total}' "http://localhost:3000/api/status" 2>/dev/null || echo "0")

response_time_ms=$(echo "$response_time * 1000" | bc 2>/dev/null | cut -d'.' -f1 || echo "0")
response_time_ms=${response_time_ms:-0}

log_info "响应时间: ${response_time_ms}ms (最大: ${max_response_time}ms)"

if [[ $response_time_ms -gt $max_response_time ]]; then
    log_error "响应时间 ${response_time_ms}ms 超过阈值 ${max_response_time}ms"
    exit 1
fi

log_info "所有健康检查通过"
exit 0
