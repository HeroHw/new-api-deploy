#!/bin/bash
#
# 停止所有容器
# 用法: ./scripts/down.sh
#

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
log_step()  { echo -e "\n${BOLD}${BLUE}▶ $1${NC}"; }
log_ok()    { echo -e "${GREEN}✅ $1${NC}"; }

log_step "停止 HAProxy..."
if docker compose -f docker-compose-haproxy.yml down 2>/dev/null; then
    log_ok "HAProxy 已停止"
else
    log_warn "HAProxy 停止失败或未运行，跳过"
fi

log_step "停止应用容器（blue / green）..."
if docker compose down 2>/dev/null; then
    log_ok "应用容器已停止"
else
    log_warn "应用容器停止失败或未运行，跳过"
fi

echo ""
log_ok "所有容器已停止"
