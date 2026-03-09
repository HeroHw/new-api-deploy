#!/bin/bash
#
# 初始化 HAProxy 容器（构建带 socat 的镜像）
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "${DEPLOY_DIR}"

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
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

# 加载 .env 文件
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    log_error ".env 文件不存在，请先创建配置文件"
    exit 1
fi

# 步骤 1: 生成 HAProxy 配置文件
log_info "步骤 1: 生成 HAProxy 配置文件..."
"${SCRIPT_DIR}/generate-haproxy-config.sh"

# 步骤 2: 构建 HAProxy 镜像
log_info "步骤 2: 构建 HAProxy 镜像（包含 socat）..."
docker compose -f docker-compose-haproxy.yml build

log_info "HAProxy 镜像构建完成"

# 步骤 3: 启动 HAProxy 容器
log_info "步骤 3: 启动 HAProxy 容器..."
docker compose -f docker-compose-haproxy.yml up -d

# 等待 HAProxy 完全启动
log_info "等待 HAProxy 完全启动..."
sleep 5

# 检查容器状态
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY:-haproxy}$"; then
    log_error "HAProxy 容器未运行"
    docker logs ${CONTAINER_HAPROXY:-haproxy}
    exit 1
fi

log_info "HAProxy 容器已启动"

# 步骤 4: 验证 socat 是否可用
log_info "步骤 4: 验证 socat 是否已安装..."
if docker exec ${CONTAINER_HAPROXY:-haproxy} which socat >/dev/null 2>&1; then
    log_info "✅ socat 已成功安装"
else
    log_error "❌ socat 安装失败"
    exit 1
fi

# 步骤 5: 验证 Runtime API socket
log_info "步骤 5: 验证 Runtime API socket..."

# 先检查 socket 文件是否存在
log_info "检查 socket 文件..."
docker exec ${CONTAINER_HAPROXY:-haproxy} ls -la /tmp/admin.sock 2>&1 || log_warn "Socket 文件不存在或无法访问"

# 检查 HAProxy 进程
log_info "检查 HAProxy 进程..."
docker exec ${CONTAINER_HAPROXY:-haproxy} ps aux | grep haproxy || true

# 等待 socket 创建（最多 10 秒）
for i in {1..10}; do
    if docker exec ${CONTAINER_HAPROXY:-haproxy} test -S /tmp/admin.sock 2>/dev/null; then
        log_info "✅ Runtime API socket 可用"
        break
    fi

    if [ $i -eq 10 ]; then
        log_error "❌ Runtime API socket 不可用"
        log_error "HAProxy 日志："
        docker logs ${CONTAINER_HAPROXY:-haproxy} 2>&1 | tail -20
        exit 1
    fi

    log_info "等待 socket 创建... ($i/10)"
    sleep 1
done

# 步骤 6: 测试 Runtime API
log_info "步骤 6: 测试 Runtime API..."
if docker exec ${CONTAINER_HAPROXY:-haproxy} sh -c "echo 'show info' | socat stdio /tmp/admin.sock" >/dev/null 2>&1; then
    log_info "✅ Runtime API 测试成功"
else
    log_error "❌ Runtime API 测试失败"
    exit 1
fi

log_info "✅ HAProxy 初始化完成，Runtime API 已就绪"
log_info ""
log_info "现在可以使用零中断的蓝绿部署了！"

