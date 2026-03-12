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

# 步骤 1: 通过 Runtime API 立即切换流量（零中断）
log_info "步骤 1/3: 通过 Runtime API 立即切换流量..."

apply_runtime_config() {
    local active=$1
    local inactive
    if [[ "$active" == "blue" ]]; then
        inactive="green"
    else
        inactive="blue"
    fi

    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/${active} state ready' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/${active} weight 100' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/${inactive} weight 0' | socat stdio ${HAPROXY_SOCKET}"
    docker exec ${CONTAINER_HAPROXY} sh -c "echo 'set server newapi_backend/${inactive} state maint' | socat stdio ${HAPROXY_SOCKET}"
}

apply_runtime_config "$TARGET_ENV"
log_info "Runtime API 切换完成，流量已切换到 ${TARGET_ENV}"

# 步骤 2: 更新磁盘上的 haproxy.cfg（持久化，防止重启回滚）
log_info "步骤 2/3: 更新 haproxy.cfg 配置文件..."
ACTIVE_ENV="${TARGET_ENV}" bash "${SCRIPT_DIR}/generate-haproxy-config.sh"

# 步骤 3: 优雅重载（刷新 DNS 解析 + 加载新配置，零中断）
log_info "步骤 3/3: 优雅重载 HAProxy（刷新 DNS 解析）..."
docker kill -s HUP ${CONTAINER_HAPROXY}

# 等待重载完成并验证 Runtime API 可用
log_info "等待 HAProxy 重载完成..."
for i in {1..30}; do
    if docker exec ${CONTAINER_HAPROXY} test -S ${HAPROXY_SOCKET} 2>/dev/null; then
        if docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show info' | socat stdio ${HAPROXY_SOCKET}" >/dev/null 2>&1; then
            log_info "✅ HAProxy 重载完成，Runtime API 已就绪"
            break
        fi
    fi

    if [ $i -eq 30 ]; then
        log_error "HAProxy 重载超时，Runtime API 不可用"
        docker logs ${CONTAINER_HAPROXY} 2>&1 | tail -20
        exit 1
    fi

    log_info "等待 Runtime API 就绪... ($i/30)"
    sleep 1
done

# 停止旧环境容器
log_info "正在停止 ${SOURCE_ENV} 环境容器..."
SOURCE_CONTAINER="${CONTAINER_BLUE}"
if [[ "$SOURCE_ENV" == "green" ]]; then
    SOURCE_CONTAINER="${CONTAINER_GREEN}"
fi

if docker ps --format '{{.Names}}' | grep -q "^${SOURCE_CONTAINER}$"; then
    docker stop ${SOURCE_CONTAINER}
    log_info "${SOURCE_ENV} 环境容器已停止"
else
    log_warn "${SOURCE_ENV} 环境容器未运行，跳过停止操作"
fi

log_info "✅ 流量切换完成，${TARGET_ENV} 环境已激活"

# 更新活跃环境记录
echo "${TARGET_ENV}" > "${DEPLOY_DIR}/.active_env"

# 记录切换历史
echo "$(date '+%Y-%m-%d %H:%M:%S') - 从 ${SOURCE_ENV} 切换到 ${TARGET_ENV}" >> "${DEPLOY_DIR}/switch-history.log"
