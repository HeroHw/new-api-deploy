#!/bin/bash
#
# 503 错误诊断脚本
# 用于排查 HAProxy 503 Service Unavailable 问题
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "${DEPLOY_DIR}"

# 加载 .env 文件
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# 设置默认值
CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# 1. 检查容器状态
log_section "1. 检查容器运行状态"

log_info "HAProxy 容器状态:"
if docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "(NAMES|${CONTAINER_HAPROXY})"; then
    log_info "✅ HAProxy 容器正在运行"
else
    log_error "❌ HAProxy 容器未运行"
    echo "尝试查看已停止的容器:"
    docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep -E "(NAMES|${CONTAINER_HAPROXY})"
fi

echo ""
log_info "Blue 环境容器状态:"
if docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "(NAMES|${CONTAINER_BLUE})"; then
    log_info "✅ Blue 容器正在运行"
else
    log_warn "⚠️  Blue 容器未运行"
fi

echo ""
log_info "Green 环境容器状态:"
if docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "(NAMES|${CONTAINER_GREEN})"; then
    log_info "✅ Green 容器正在运行"
else
    log_warn "⚠️  Green 容器未运行"
fi

# 2. 检查网络连接
log_section "2. 检查 Docker 网络"

NETWORK_NAME=${NETWORK_NAME:-deploy-network}
log_info "检查网络 ${NETWORK_NAME}:"
if docker network inspect ${NETWORK_NAME} >/dev/null 2>&1; then
    log_info "✅ 网络存在"
    echo ""
    log_info "网络中的容器:"
    docker network inspect ${NETWORK_NAME} --format '{{range .Containers}}{{.Name}} - {{.IPv4Address}}{{"\n"}}{{end}}'
else
    log_error "❌ 网络 ${NETWORK_NAME} 不存在"
fi

# 3. 检查 HAProxy 配置
log_section "3. 检查 HAProxy 配置"

if [ -f "haproxy.cfg" ]; then
    log_info "✅ haproxy.cfg 文件存在"
    echo ""
    log_info "后端服务器配置:"
    grep -A 10 "backend newapi_backend" haproxy.cfg || log_warn "未找到 backend 配置"
else
    log_error "❌ haproxy.cfg 文件不存在"
fi

# 4. 检查 HAProxy Runtime API 状态
log_section "4. 检查 HAProxy Runtime API 状态"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
    log_info "检查 socat 是否可用:"
    if docker exec ${CONTAINER_HAPROXY} which socat >/dev/null 2>&1; then
        log_info "✅ socat 已安装"
    else
        log_error "❌ socat 未安装"
    fi

    echo ""
    log_info "检查 Runtime API socket:"
    if docker exec ${CONTAINER_HAPROXY} test -S /tmp/admin.sock 2>/dev/null; then
        log_info "✅ Socket 可用"

        echo ""
        log_info "HAProxy 后端服务器状态:"
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show servers state' | socat stdio /tmp/admin.sock" 2>/dev/null || log_error "无法获取服务器状态"

        echo ""
        log_info "HAProxy 统计信息:"
        docker exec ${CONTAINER_HAPROXY} sh -c "echo 'show stat' | socat stdio /tmp/admin.sock" 2>/dev/null | grep -E "(newapi_backend|FRONTEND|BACKEND)" || log_error "无法获取统计信息"
    else
        log_error "❌ Socket 不可用"
    fi
else
    log_warn "HAProxy 容器未运行，跳过 Runtime API 检查"
fi

# 5. 检查后端应用健康状态
log_section "5. 检查后端应用健康状态"

check_app_health() {
    local container=$1
    local env_name=$2

    log_info "检查 ${env_name} 环境 (${container}):"

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        # 检查容器内部健康检查
        if docker exec ${container} curl -sf "http://localhost:3000/api/status" > /dev/null 2>&1; then
            log_info "✅ ${env_name} 应用健康检查通过"
            docker exec ${container} curl -s "http://localhost:3000/api/status" | head -5
        else
            log_error "❌ ${env_name} 应用健康检查失败"
            echo "尝试访问根路径:"
            docker exec ${container} curl -I "http://localhost:3000/" 2>&1 | head -10
        fi

        echo ""
        log_info "${env_name} 应用日志 (最后 10 行):"
        docker logs ${container} --tail 10 2>&1
    else
        log_warn "⚠️  ${env_name} 容器未运行"
    fi
    echo ""
}

check_app_health "${CONTAINER_BLUE}" "Blue"
check_app_health "${CONTAINER_GREEN}" "Green"

# 6. 从 HAProxy 容器测试后端连接
log_section "6. 从 HAProxy 测试后端连接"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
    log_info "从 HAProxy 容器测试 Blue 环境连接:"
    docker exec ${CONTAINER_HAPROXY} wget -qO- --timeout=5 "http://${CONTAINER_BLUE}:3000/api/status" 2>&1 || log_error "无法连接到 Blue 环境"

    echo ""
    log_info "从 HAProxy 容器测试 Green 环境连接:"
    docker exec ${CONTAINER_HAPROXY} wget -qO- --timeout=5 "http://${CONTAINER_GREEN}:3000/api/status" 2>&1 || log_error "无法连接到 Green 环境"
else
    log_warn "HAProxy 容器未运行，跳过连接测试"
fi

# 7. 检查 HAProxy 日志
log_section "7. HAProxy 日志 (最后 20 行)"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
    docker logs ${CONTAINER_HAPROXY} --tail 20 2>&1
else
    log_warn "HAProxy 容器未运行，无法查看日志"
fi

# 8. 检查活跃环境配置
log_section "8. 检查活跃环境配置"

ACTIVE_ENV_FILE="${DEPLOY_DIR}/.active_env"
if [ -f "$ACTIVE_ENV_FILE" ]; then
    ACTIVE_ENV=$(cat "$ACTIVE_ENV_FILE")
    log_info "当前活跃环境: ${ACTIVE_ENV}"
else
    log_warn "未找到 .active_env 文件"
fi

# 9. 总结和建议
log_section "9. 诊断总结和建议"

echo ""
log_info "常见 503 错误原因和解决方案:"
echo ""
echo "1. 后端容器未运行"
echo "   解决: docker compose up -d (启动应用容器)"
echo ""
echo "2. 后端应用未启动或启动失败"
echo "   解决: 检查应用日志 docker logs <container>"
echo ""
echo "3. HAProxy 配置中的后端服务器地址错误"
echo "   解决: 检查 haproxy.cfg 中的 server 配置"
echo ""
echo "4. 网络连接问题"
echo "   解决: 确保所有容器在同一网络中"
echo ""
echo "5. 后端服务器被标记为 MAINT 或 DOWN"
echo "   解决: 使用 switch-traffic.sh 切换到健康的环境"
echo ""
echo "6. 应用端口不正确"
echo "   解决: 确认应用监听 3000 端口"
echo ""

log_info "快速修复命令:"
echo ""
echo "# 查看当前 HAProxy 后端状态"
echo "docker exec ${CONTAINER_HAPROXY} sh -c \"echo 'show stat' | socat stdio /tmp/admin.sock\" | grep newapi_backend"
echo ""
echo "# 手动启用某个后端"
echo "docker exec ${CONTAINER_HAPROXY} sh -c \"echo 'set server newapi_backend/blue state ready' | socat stdio /tmp/admin.sock\""
echo "docker exec ${CONTAINER_HAPROXY} sh -c \"echo 'set server newapi_backend/blue weight 100' | socat stdio /tmp/admin.sock\""
echo ""
echo "# 或使用流量切换脚本"
echo "./scripts/switch-traffic.sh blue"
echo ""
