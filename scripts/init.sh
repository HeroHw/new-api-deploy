#!/bin/bash
#
# 初始化部署环境脚本
# 用法: ./init.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEPLOY_DIR"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

log_info "初始化蓝绿发布环境..."

# 检查 .env 文件
if [[ ! -f ".env" ]]; then
    log_warn ".env 文件不存在，从模板创建..."
    cp .env.example .env
    log_info ".env 文件已创建，使用默认配置"
fi

# 加载环境变量
export $(grep -v '^#' .env | xargs)

# 设置默认值
CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}
NETWORK_NAME=${NETWORK_NAME:-deploy-network}
HAPROXY_HTTP_PORT=${HAPROXY_HTTP_PORT:-80}

# 验证必要的镜像配置
if [[ -z "$ACR_REGISTRY" || "$ACR_REGISTRY" == "your-registry.azurecr.io" ]]; then
    log_error "请在 .env 文件中��置 ACR_REGISTRY"
    exit 1
fi

if [[ -z "$APP_NAME" ]]; then
    log_error "请在 .env 文件中配置 APP_NAME"
    exit 1
fi

# 检查 Docker 是否运行
if ! docker info &> /dev/null; then
    log_error "Docker 未运行，请先启动 Docker"
    exit 1
fi

# 生成 HAProxy 配置
log_info "生成 HAProxy 配置..."
./scripts/generate-haproxy-config.sh

# 创建 Docker 网络
log_info "创建 Docker 网络..."
docker network create ${NETWORK_NAME} 2>/dev/null || log_info "网络 ${NETWORK_NAME} 已存在"

# 设置初始活跃环境
echo "blue" > .active_env

# 设置脚本执行权限
chmod +x scripts/*.sh

# 启动应用容器
log_info "启动应用容器..."
docker compose up -d

# 启动 HAProxy 容器
log_info "启动 HAProxy 容器..."
docker compose -f docker-compose-haproxy.yml up -d

# 等待服务启动
log_info "等待服务启动..."
sleep 10

# 显示状态
./scripts/status.sh

log_info "初始化完成!"
log_info "应用访问地址: http://localhost:${HAPROXY_HTTP_PORT}"
