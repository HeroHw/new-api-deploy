# 部署文档

本项目采用 Docker + HAProxy 实现蓝绿部署和灰度发布。

## 架构说明

- **应用容器**: app-blue 和 app-green 两个容器，运行在 `deploy-network` 网络中
- **负载均衡**: HAProxy 容器，通过 Docker 部署，负责流量分发
- **端口映射**:
  - HAProxy 80 端口对外提供服务
  - HAProxy 8404 端口提供统计页面
  - 应用容器不对外暴露端口，仅在内部网络通信

## 目录结构

```
deploy/
├── .env.example                 # 环境变量配置模板
├── docker-compose.yml           # 应用容器配置
├── docker-compose-haproxy.yml   # HAProxy 容器配置
├── haproxy.cfg                  # HAProxy 配置文件（生成）
├── haproxy.cfg.template         # HAProxy 配置模板
├── scripts/
│   ├── generate-haproxy-config.sh  # HAProxy 配置生成脚本
│   ├── switch-traffic.sh        # 流量切换脚本
│   ├── set-canary-weight.sh     # 灰度权重设置脚本
│   ├── check-canary-health.sh   # 灰度健康检查脚本
│   ├── init.sh                  # 初始化脚本
│   ├── status.sh                # 状态查看脚本
│   └── rollback.sh              # 回滚脚本
├── jenkinsfile                  # Jenkins 流水线配置
└── README.md                    # 本文档
```

## 首次部署

### 1. 准备环境

在部署服务器上创建部署目录：

```bash
mkdir -p /opt/newapi-test
cd /opt/newapi-test
```

### 2. 上传部署文件

将以下文件上传到服务器：
- `docker-compose.yml`
- `docker-compose-haproxy.yml`
- `haproxy.cfg.template`
- `.env.example`
- `scripts/` 目录及其内容

### 3. 配置环境变量

复制环境变量模板并编辑：

```bash
cp .env.example .env
vi .env
```

配置以下必要参数：

```bash
# 镜像配置（必填）
ACR_REGISTRY=your-registry.azurecr.io
APP_NAME=new-api-test
BLUE_TAG=latest
GREEN_TAG=latest

# 容器名称配置（可选，使用默认值）
CONTAINER_BLUE=app-blue
CONTAINER_GREEN=app-green
CONTAINER_HAPROXY=haproxy

# 网络配置（可选，使用默认值）
NETWORK_NAME=deploy-network

# 端口配置（可选，使用默认值）
HAPROXY_HTTP_PORT=80
```

**注意**:
- `ACR_REGISTRY` 和 `APP_NAME` 是必填项
- `BLUE_TAG` 和 `GREEN_TAG` 默认为 `latest`，Jenkins 部署时会自动更新为具体的版本标签

### 4. 生成 HAProxy 配置

```bash
./scripts/generate-haproxy-config.sh
```

### 5. 创建 Docker 网络

```bash
docker network create deploy-network
```

### 6. 启动应用容器

```bash
docker compose up -d
```

### 7. 启动 HAProxy

```bash
docker compose -f docker-compose-haproxy.yml up -d
```

### 8. 验证部署

访问服务：
```bash
curl http://localhost/api/status
```

查看 HAProxy 统计页面：
```bash
curl http://localhost:8404
```

或使用初始化脚本一键部署：

```bash
./scripts/init.sh
```

## Jenkins 自动化部署

### 配置 Jenkins 凭据

在 Jenkins 中配置以下凭据：

1. **acr-docker-registry**: ACR 镜像仓库地址
2. **acr-docker-password**: ACR 登录凭据（用户名/密码）
3. **deploy-server-ssh**: 部署服务器 SSH 密钥
4. **github-token**: GitHub 访问令牌
5. **feishu-webhook**: 飞书机器人 Webhook URL

### 部署模式

Jenkins 流水线支持三种部署模式：

1. **canary (灰度发布)**: 逐步增加新版本流量比例
2. **blue-green (蓝绿切换)**: 直接切换到新版本
3. **direct (直接切换)**: 跳过健康检查直接切换

### 部署流程

1. **拉取代码**: 从 Git 仓库拉取最新代码
2. **构建镜像**: 使用 Docker 构建应用镜像
3. **推送镜像**: 推送到 ACR 镜像仓库
4. **确定目标环境**: 自动选择非活跃环境（blue/green）
5. **部署到目标环境**: 更新目标环境容器
6. **健康检查**: 验证新版本健康状态
7. **灰度发布** (可选): 按阶梯逐步增加流量
8. **流量切换**: 将 100% 流量切换到新版本
9. **验证部署**: 最终验证
10. **标记稳定版本**: 打上 latest 标签

### 灰度发布参数

- **CANARY_PERCENTAGE**: 灰度流量比例阶梯，如 `10,30,50,100`
- **CANARY_WAIT_TIME**: 每个阶梯等待时间（秒）
- **AUTO_PROMOTE**: 是否自动提升到 100%

## 手动操作

### 查看当前状态

```bash
cd /opt/newapi-test
./scripts/status.sh
```

### 手动切换流量

切换到 blue 环境：
```bash
./scripts/switch-traffic.sh blue
```

切换到 green 环境：
```bash
./scripts/switch-traffic.sh green
```

### 设置灰度权重

将 30% 流量分配给 green 环境：
```bash
./scripts/set-canary-weight.sh blue green 30
```

### 回滚到上一个版本

```bash
./scripts/rollback.sh
```

## 容器管理

### 查看容器状态

```bash
docker ps -a | grep -E "app-blue|app-green|haproxy"
```

### 查看容器日志

```bash
# 查看应用日志
docker logs -f app-blue
docker logs -f app-green

# 查看 HAProxy 日志
docker logs -f haproxy
```

### 重启容器

```bash
# 重启应用容器
docker compose restart app-blue
docker compose restart app-green

# 重启 HAProxy
docker compose -f docker-compose-haproxy.yml restart haproxy
```

### 停止服务

```bash
# 停止应用容器
docker compose down

# 停止 HAProxy
docker compose -f docker-compose-haproxy.yml down
```

## HAProxy 管理

### 访问 HAProxy Stats 页面

浏览器访问: `http://<server-ip>:8404`

### 使用 Runtime API

进入 HAProxy 容器：
```bash
docker exec -it haproxy sh
```

查看服务器状态：
```bash
echo "show servers state" | socat stdio /run/haproxy/admin.sock
```

设置服务器权重：
```bash
echo "set server newapi_backend/blue weight 50" | socat stdio /run/haproxy/admin.sock
```

### 重新加载配置

修改配置文件后重新加载：
```bash
cd /opt/newapi-test
docker compose -f docker-compose-haproxy.yml restart haproxy
```

## 网络配置

应用容器和 HAProxy 容器共享 `deploy-network` 网络：

- **网络名称**: deploy-network（可通过 .env 配置）
- **网络类型**: bridge
- **容器通信**: 通过容器名称互相访问
  - `app-blue:3000`（容器名可通过 .env 配置）
  - `app-green:3000`（容器名可通过 .env 配置）

## 环境变量配置

所有容器名称、网络名称、端口和镜像配置都可以通过根目录的 `.env` 文件配置：

| 变量名 | 说明 | 默认值 | 是否必填 |
|--------|------|--------|----------|
| `ACR_REGISTRY` | ACR 镜像仓库地址 | - | 是 |
| `APP_NAME` | 应用名称 | - | 是 |
| `BLUE_TAG` | Blue 环境镜像标签 | latest | 否 |
| `GREEN_TAG` | Green 环境镜像标签 | latest | 否 |
| `CONTAINER_BLUE` | Blue 容器名称 | app-blue | 否 |
| `CONTAINER_GREEN` | Green 容器名称 | app-green | 否 |
| `CONTAINER_HAPROXY` | HAProxy 容器名称 | haproxy | 否 |
| `NETWORK_NAME` | Docker 网络名称 | deploy-network | 否 |
| `HAPROXY_HTTP_PORT` | HAProxy HTTP 端口 | 80 | 否 |

修改 `.env` 文件后，需要：
1. 如果修改了容器名称：重新生成 HAProxy 配置 `./scripts/generate-haproxy-config.sh`
2. 重启容器：`docker compose down && docker compose up -d`

## 故障排查

### 健康检查失败

1. 检查容器是否正常运行：
   ```bash
   docker ps
   ```

2. 查看容器日志：
   ```bash
   docker logs app-blue
   docker logs app-green
   ```

3. 手动测试健康检查：
   ```bash
   docker exec app-blue curl -f http://localhost:3000/api/status
   ```

### HAProxy 无法访问应用

1. 检查网络连接：
   ```bash
   docker network inspect deploy-network
   ```

2. 测试容器间通信：
   ```bash
   docker exec haproxy ping app-blue
   docker exec haproxy ping app-green
   ```

3. 检查 HAProxy 配置：
   ```bash
   docker exec haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
   ```

### 流量切换失败

1. 检查 HAProxy socket：
   ```bash
   docker exec haproxy test -S /run/haproxy/admin.sock && echo "OK" || echo "FAIL"
   ```

2. 查看 HAProxy 日志：
   ```bash
   docker logs haproxy
   ```

3. 手动执行切换命令：
   ```bash
   docker exec haproxy sh -c "echo 'show servers state' | socat stdio /run/haproxy/admin.sock"
   ```

## 监控和日志

### 查看部署历史

```bash
# 查看流量切换历史
cat /opt/newapi-test/switch-history.log

# 查看灰度发布历史
cat /opt/newapi-test/canary-history.log
```

### 查看当前活跃环境

```bash
cat /opt/newapi-test/.active_env
```

## 安全建议

1. **敏感信息**: 不要在配置文件中硬编码敏感信息，使用环境变量或密钥管理服务
2. **网络隔离**: 确保 deploy-network 网络仅供内部容器使用
3. **访问控制**: 限制 HAProxy stats 页面的访问权限
4. **日志审计**: 定期检查部署和切换日志

## 性能优化

1. **连接池**: 根据负载调整数据库和 Redis 连接池大小
2. **超时设置**: 根据实际情况调整 HAProxy 超时参数
3. **健康检查**: 调整健康检查间隔和重试次数
4. **资源限制**: 为容器设置合理的 CPU 和内存限制

## 备份和恢复

### 备份配置文件

```bash
tar -czf deploy-backup-$(date +%Y%m%d).tar.gz \
  docker-compose.yml \
  docker-compose-haproxy.yml \
  haproxy.cfg.template \
  scripts/ \
  .active_env \
  *-history.log
```

### 恢复配置

```bash
tar -xzf deploy-backup-YYYYMMDD.tar.gz
```

## 联系方式

如有问题，请联系运维团队或查看项目文档。
