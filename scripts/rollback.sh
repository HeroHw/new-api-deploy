#!/bin/bash
#
# 快速回滚到上一版本
# 用法: ./scripts/rollback.sh
#
# 逻辑:
#   1. 确定当前活跃环境（active），回滚目标为另一个（target）
#   2. 若 target 容器未运行，先 docker compose up 拉起
#   3. 等待 target 健康
#   4. 通过 HAProxy Runtime API 无中断切换流量
#   5. 更新 haproxy.cfg 并 reload
#   6. 更新 .active_env 记录
#   注: 不停止原容器，保留双活状态供再次回滚使用
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

cd "$DEPLOY_DIR"

# ─── 颜色输出 ─────────────────────────────────────────────────────────────────
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

# ─── 加载 .env ────────────────────────────────────────────────────────────────
if [[ -f ".env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    done < .env
fi

CONTAINER_BLUE=${CONTAINER_BLUE:-app-blue}
CONTAINER_GREEN=${CONTAINER_GREEN:-app-green}
CONTAINER_HAPROXY=${CONTAINER_HAPROXY:-haproxy}
HAPROXY_SOCKET="/tmp/admin.sock"

# ─── 确定回滚方向 ─────────────────────────────────────────────────────────────
ACTIVE_ENV=$(cat .active_env 2>/dev/null || echo "blue")

if [[ "$ACTIVE_ENV" == "blue" ]]; then
    TARGET_ENV="green"
    TARGET_CONTAINER="${CONTAINER_GREEN}"
    TARGET_SERVICE="app-green"
else
    TARGET_ENV="blue"
    TARGET_CONTAINER="${CONTAINER_BLUE}"
    TARGET_SERVICE="app-blue"
fi

log_step "回滚方向: ${ACTIVE_ENV} → ${TARGET_ENV}"

# ─── 检查 HAProxy ─────────────────────────────────────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_HAPROXY}$"; then
    log_error "HAProxy 容器未运行，无法回滚"
    exit 1
fi

if ! docker exec "${CONTAINER_HAPROXY}" test -S "${HAPROXY_SOCKET}" 2>/dev/null; then
    log_error "HAProxy Runtime API socket 不可用"
    exit 1
fi

# ─── 拉起目标容器（如果未运行）────────────────────────────────────────────────
log_step "检查目标容器状态..."

if ! docker ps --format '{{.Names}}' | grep -q "^${TARGET_CONTAINER}$"; then
    log_warn "${TARGET_ENV} 容器未运行，正在启动..."
    docker compose up -d "${TARGET_SERVICE}"
    log_info "${TARGET_ENV} 容器已启动，等待就绪..."
else
    log_info "${TARGET_ENV} 容器已在运行"
fi

# ─── 等待目标容器健康 ─────────────────────────────────────────────────────────
log_step "等待 ${TARGET_ENV} 容器健康检查通过（最多 60s）..."

for i in {1..60}; do
    if docker exec "${TARGET_CONTAINER}" curl -sf "http://localhost:3000/api/status" &>/dev/null; then
        log_ok "${TARGET_ENV} 容器已就绪"
        break
    fi

    if [[ $i -eq 60 ]]; then
        log_error "${TARGET_ENV} 容器启动超时，查看日志："
        docker logs "${TARGET_CONTAINER}" 2>&1 | tail -20
        exit 1
    fi

    if [[ $((i % 10)) -eq 0 ]]; then
        log_info "等待中... (${i}/60)"
    fi
    sleep 1
done

# ─── 通过 Runtime API 切换流量（零中断）──────────────────────────────────────
log_step "步骤 1/3: 通过 HAProxy Runtime API 切换流量..."

docker exec "${CONTAINER_HAPROXY}" sh -c "echo 'set server newapi_backend/${TARGET_ENV} state ready'  | socat stdio ${HAPROXY_SOCKET}"
docker exec "${CONTAINER_HAPROXY}" sh -c "echo 'set server newapi_backend/${TARGET_ENV} weight 100'   | socat stdio ${HAPROXY_SOCKET}"
docker exec "${CONTAINER_HAPROXY}" sh -c "echo 'set server newapi_backend/${ACTIVE_ENV} weight 0'    | socat stdio ${HAPROXY_SOCKET}"
docker exec "${CONTAINER_HAPROXY}" sh -c "echo 'set server newapi_backend/${ACTIVE_ENV} state maint' | socat stdio ${HAPROXY_SOCKET}"

log_ok "流量已切换到 ${TARGET_ENV}"

# ─── 更新 haproxy.cfg 并 reload ───────────────────────────────────────────────
log_step "步骤 2/3: 更新 haproxy.cfg..."
ACTIVE_ENV="${TARGET_ENV}" bash "${SCRIPT_DIR}/generate-haproxy-config.sh"

log_step "步骤 3/3: 优雅重载 HAProxy..."
docker kill -s HUP "${CONTAINER_HAPROXY}"

for i in {1..30}; do
    if docker exec "${CONTAINER_HAPROXY}" test -S "${HAPROXY_SOCKET}" 2>/dev/null; then
        if docker exec "${CONTAINER_HAPROXY}" sh -c "echo 'show info' | socat stdio ${HAPROXY_SOCKET}" &>/dev/null; then
            log_ok "HAProxy 重载完成"
            break
        fi
    fi

    if [[ $i -eq 30 ]]; then
        log_error "HAProxy 重载超时"
        docker logs "${CONTAINER_HAPROXY}" 2>&1 | tail -20
        exit 1
    fi
    sleep 1
done

# ─── 更新状态记录 ─────────────────────────────────────────────────────────────
echo "${TARGET_ENV}" > .active_env
echo "$(date '+%Y-%m-%d %H:%M:%S') - [ROLLBACK] 从 ${ACTIVE_ENV} 回滚到 ${TARGET_ENV}" >> switch-history.log

# ─── 完成 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}========================================${NC}"
echo -e "${BOLD}${GREEN}   回滚完成！${NC}"
echo -e "${BOLD}${GREEN}========================================${NC}"
echo ""
echo -e "  当前活跃环境: ${BOLD}${TARGET_ENV}${NC}"
echo -e "  原环境 (${ACTIVE_ENV}) 仍在运行，可再次回滚"
echo ""
echo -e "  查看状态: bash scripts/status.sh"
echo ""
