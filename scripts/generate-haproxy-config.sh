#!/bin/bash
#
# 生成 HAProxy 配置文件
# 从 .env 文件读取变量并替换模板
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
HAPROXY_DIR="${DEPLOY_DIR}"

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 加载 .env 文件
if [ -f "${DEPLOY_DIR}/.env" ]; then
    log_info "加载配置文件: ${DEPLOY_DIR}/.env"
    set -a; source "${DEPLOY_DIR}/.env"; set +a
else
    log_error ".env 文件不存在，请先创建配置文件"
    log_error "可以复制 .env.example 并修改: cp .env.example .env"
    exit 1
fi

# 设置默认值
CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
ACTIVE_ENV=${ACTIVE_ENV:-blue}

if [[ "$ACTIVE_ENV" != "blue" && "$ACTIVE_ENV" != "green" ]]; then
    log_error "无效的 ACTIVE_ENV: ${ACTIVE_ENV}，必须是 'blue' 或 'green'"
    exit 1
fi

if [[ "$ACTIVE_ENV" == "blue" ]]; then
    BLUE_STATUS="weight 100"
    GREEN_STATUS="weight 0 disabled"
else
    BLUE_STATUS="weight 0 disabled"
    GREEN_STATUS="weight 100"
fi

log_info "容器配置:"
log_info "  Blue 容器: ${CONTAINER_BLUE}"
log_info "  Green 容器: ${CONTAINER_GREEN}"
log_info "  激活环境: ${ACTIVE_ENV}"

# 检查模板文件
if [ ! -f "${HAPROXY_DIR}/haproxy.cfg.template" ]; then
    log_error "模板文件不存在: ${HAPROXY_DIR}/haproxy.cfg.template"
    exit 1
fi

# 生成配置文件
log_info "生成 HAProxy 配置文件（激活环境: ${ACTIVE_ENV}）..."
sed -e "s/{{CONTAINER_BLUE}}/${CONTAINER_BLUE}/g" \
    -e "s/{{CONTAINER_GREEN}}/${CONTAINER_GREEN}/g" \
    -e "s/{{ACTIVE_ENV}}/${ACTIVE_ENV}/g" \
    -e "s|{{BLUE_STATUS}}|${BLUE_STATUS}|g" \
    -e "s|{{GREEN_STATUS}}|${GREEN_STATUS}|g" \
    "${HAPROXY_DIR}/haproxy.cfg.template" > "${HAPROXY_DIR}/haproxy.cfg"

log_info "配置文件已生成: ${HAPROXY_DIR}/haproxy.cfg"

# 验证配置文件
if command -v docker &> /dev/null; then
    log_info "验证配置文件语法..."
    # 使用 -c 检查语法，-dM 跳过 DNS 解析
    # 注意：即使容器不存在，配置文件也是有效的，HAProxy 会在运行时动态解析
    if docker run --rm -v "${HAPROXY_DIR}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" haproxy:2.9-alpine haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg -dM 2>&1; then
        log_info "配置文件验证通过"
    else
        log_error "配置文件验证失败"
        exit 1
    fi
fi

log_info "完成"
