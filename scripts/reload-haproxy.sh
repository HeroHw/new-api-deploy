#!/bin/bash
#
# HAProxy 热重载脚本 - 不中断现有连接
# 用法: ./scripts/reload-haproxy.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEPLOY_DIR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}${BLUE}▶ $1${NC}"; }
log_ok()    { echo -e "${GREEN}✅ $1${NC}"; }

# 加载 .env
if [[ ! -f ".env" ]]; then
    log_error ".env 文件不存在"
    exit 1
fi
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
done < .env

CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}
CFG_PATH="/usr/local/etc/haproxy/haproxy.cfg"

# ─── 检查容器是否运行 ──────────────────────────────────────────────────────────

log_step "检查 HAProxy 容器状态..."

if ! docker inspect --format '{{.State.Running}}' "${CONTAINER_HAPROXY}" 2>/dev/null | grep -q true; then
    log_error "容器 ${CONTAINER_HAPROXY} 未运行"
    exit 1
fi

log_info "容器 ${CONTAINER_HAPROXY} 运行中"

# ─── 验证配置文件语法 ──────────────────────────────────────────────────────────

log_step "验证配置文件语法..."

if ! docker exec "${CONTAINER_HAPROXY}" haproxy -c -f "${CFG_PATH}" 2>&1; then
    log_error "配置文件语法错误，热重载已取消"
    exit 1
fi

log_ok "配置文件验证通过"

# ─── 热重载 ───────────────────────────────────────────────────────────────────

log_step "发送 HUP 信号执行热重载..."

docker kill --signal=HUP "${CONTAINER_HAPROXY}"

log_ok "热重载信号已发送（现有连接不会中断）"

# ─── 等待重载完成 ──────────────────────────────────────────────────────────────

sleep 1

if docker inspect --format '{{.State.Running}}' "${CONTAINER_HAPROXY}" 2>/dev/null | grep -q true; then
    log_ok "HAProxy 热重载完成，容器运行正常"
else
    log_error "热重载后容器异常，请检查日志："
    echo "  docker logs ${CONTAINER_HAPROXY} --tail 30"
    exit 1
fi
