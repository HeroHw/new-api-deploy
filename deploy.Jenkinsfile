// ============================================
// Deploy Job - 蓝绿部署 + 灰度发布 + 自动回滚
// ============================================
pipeline {
    agent any

    environment {
        // ACR 配置
        ACR_REGISTRY = credentials('acr-docker-registry')
        ACR_CREDENTIALS = credentials('acr-docker-password')
        APP_NAME = 'apiqik'
        PROJECT_NAME = '测试-中转站'

        // 部署服务器配置
        DEPLOY_HOST = credentials('deploy-ip')
        DEPLOY_USER = credentials('deploy-user')
        DEPLOY_PATH = '/opt/newapi-test'
        SSH_CREDENTIALS_ID = 'deploy-server-ssh'

        // 飞书机器人配置
        FEISHU_WEBHOOK = credentials('feishu-webhook')
    }

    parameters {
        // IMAGE_TAG 参数（只读，由 Build Job 传递）
        string(
            name: 'IMAGE_TAG',
            defaultValue: '',
            description: '镜像标签（由 Build Job 自动传递，禁止手动输入）'
        )
        string(
            name: 'GIT_COMMIT',
            defaultValue: '',
            description: 'Git 提交哈希（由 Build Job 传递）'
        )
        string(
            name: 'GIT_COMMIT_MSG',
            defaultValue: '',
            description: 'Git 提交信息（由 Build Job 传递）'
        )
        string(
            name: 'BUILD_NUMBER_FROM_CI',
            defaultValue: '',
            description: 'CI 构建编号（由 Build Job 传递）'
        )

        // 部署模式选择
        choice(
            name: 'DEPLOY_MODE',
            choices: ['canary', 'blue-green', 'direct'],
            description: '部署模式: canary=灰度发布, blue-green=蓝绿切换, direct=直接切换'
        )

        // 灰度发布配置
        string(
            name: 'CANARY_PERCENTAGE',
            defaultValue: '10,30,50,100',
            description: '灰度流量比例阶梯 (逗号分隔)'
        )
        string(
            name: 'CANARY_WAIT_TIME',
            defaultValue: '60',
            description: '每个灰度阶梯等待时间(秒)'
        )
        booleanParam(
            name: 'AUTO_PROMOTE',
            defaultValue: true,
            description: '灰度验证通过后自动提升到100%'
        )

        // 回滚选项
        booleanParam(
            name: 'IS_ROLLBACK',
            defaultValue: false,
            description: '是否为回滚操作'
        )
    }

    stages {
        stage('参数校验') {
            steps {
                script {
                    echo "========== 参数校验 =========="

                    // 校验 IMAGE_TAG 是否为空
                    if (!params.IMAGE_TAG || params.IMAGE_TAG.trim() == '') {
                        error("❌ IMAGE_TAG 参数为空！此参数必须由 Build Job 自动传递，禁止手动触发此 Job。")
                    }

                    // 校验 IMAGE_TAG 格式（防止用户手动输入 latest 等不安全标签）
                    if (params.IMAGE_TAG == 'latest' || params.IMAGE_TAG == 'stable') {
                        error("❌ 禁止使用 'latest' 或 'stable' 作为镜像标签！请使用具体版本号。")
                    }

                    // 校验镜像标签格式（必须符合：v20260304）
                    if (!params.IMAGE_TAG.matches(/^v\d{8}$/)) {
                        error("❌ IMAGE_TAG 格式不正确！期望格式: v20260304")
                    }

                    echo "✅ IMAGE_TAG 校验通过: ${params.IMAGE_TAG}"
                    echo "部署模式: ${params.DEPLOY_MODE}"
                    echo "是否回滚: ${params.IS_ROLLBACK}"
                }
            }
        }

        stage('镜像存在性校验') {
            steps {
                script {
                    echo "========== 镜像存在性校验 =========="

                    def fullImage = "${ACR_REGISTRY}/${APP_NAME}:${params.IMAGE_TAG}"
                    echo "正在校验镜像: ${fullImage}"

                    try {
                        def manifestCheck = sh(
                            script: """
                                echo "${ACR_CREDENTIALS_PSW}" | docker login "${ACR_REGISTRY}" -u "${ACR_CREDENTIALS_USR}" --password-stdin
                                docker manifest inspect "${fullImage}"
                            """,
                            returnStatus: true
                        )

                        if (manifestCheck != 0) {
                            error("❌ 镜像不存在或无法访问: ${fullImage}")
                        }

                        echo "✅ 镜像存在性校验通过"

                    } catch (Exception e) {
                        error("❌ 镜像校验失败: ${e.message}\n请确认镜像已成功构建并推送到 ACR。")
                    }
                }
            }
        }

        stage('确定目标环境') {
            steps {
                script {
                    echo "========== 确定目标环境 =========="

                    // 获取当前活跃环境
                    def currentEnv
                    sshagent([SSH_CREDENTIALS_ID]) {
                        currentEnv = sh(
                            script: """
                                ssh -o StrictHostKeyChecking=no ${DEPLOY_USER}@${DEPLOY_HOST} \
                                'cat ${DEPLOY_PATH}/.active_env 2>/dev/null || echo none'
                            """,
                            returnStdout: true
                        ).trim()
                    }

                    env.CURRENT_ENV = currentEnv

                    // 确定目标环境
                    if (currentEnv == 'none') {
                        env.TARGET_ENV = 'blue'
                        echo "首次部署，目标环境: blue"
                    } else {
                        env.TARGET_ENV = (currentEnv == 'blue') ? 'green' : 'blue'
                        echo "当前活跃环境: ${env.CURRENT_ENV}"
                        echo "部署目标环境: ${env.TARGET_ENV}"
                    }
                }
            }
        }

        stage('部署到目标环境') {
            steps {
                script {
                    echo "========== 部署到目标环境 =========="

                    def fullImage = "${ACR_REGISTRY}/${APP_NAME}:${params.IMAGE_TAG}"
                    def targetEnv = env.TARGET_ENV

                    echo "正在部署 ${params.IMAGE_TAG} 到 ${targetEnv} 环境"

                    try {
                        sshagent([SSH_CREDENTIALS_ID]) {
                            sh """
                                ssh -o StrictHostKeyChecking=no ${DEPLOY_USER}@${DEPLOY_HOST} << 'ENDSSH'
                                    cd ${DEPLOY_PATH}

                                    # 加载 .env 文件
                                    if [ -f .env ]; then
                                        export \$(grep -v '^#' .env | xargs)
                                    fi
                                    CONTAINER_BLUE=\${CONTAINER_BLUE:-app-blue}
                                    CONTAINER_GREEN=\${CONTAINER_GREEN:-app-green}

                                    # 确保脚本有执行权限
                                    chmod +x ${DEPLOY_PATH}/scripts/*.sh 2>/dev/null || true

                                    # 登录 ACR
                                    echo '${ACR_CREDENTIALS_PSW}' | docker login ${ACR_REGISTRY} -u ${ACR_CREDENTIALS_USR} --password-stdin

                                    # 拉取新镜像
                                    docker pull ${fullImage}

                                    # 设置环境变量
                                    if [ "${targetEnv}" = "blue" ]; then
                                        export BLUE_TAG="${params.IMAGE_TAG}"
                                        export GREEN_TAG=\$(docker inspect \$CONTAINER_GREEN --format='{{.Config.Image}}' 2>/dev/null | awk -F: '{print \$NF}' | tr -d '[:space:]')
                                        export GREEN_TAG=\${GREEN_TAG:-${params.IMAGE_TAG}}
                                        OTHER_CONTAINER="\$CONTAINER_GREEN"
                                    else
                                        export GREEN_TAG="${params.IMAGE_TAG}"
                                        export BLUE_TAG=\$(docker inspect \$CONTAINER_BLUE --format='{{.Config.Image}}' 2>/dev/null | awk -F: '{print \$NF}' | tr -d '[:space:]')
                                        export BLUE_TAG=\${BLUE_TAG:-${params.IMAGE_TAG}}
                                        OTHER_CONTAINER="\$CONTAINER_BLUE"
                                    fi

                                    export ACR_REGISTRY="${ACR_REGISTRY}"
                                    export APP_NAME="${APP_NAME}"

                                    # 部署逻辑
                                    if [ "${env.CURRENT_ENV}" = "none" ]; then
                                        echo "首次部署，启动 blue 和 green 两个环境"
                                        export BLUE_TAG="${params.IMAGE_TAG}"
                                        export GREEN_TAG="${params.IMAGE_TAG}"
                                        docker compose up -d app-blue app-green
                                    elif ! docker ps -a --format '{{.Names}}' | grep -q "^\${OTHER_CONTAINER}\$"; then
                                        echo "另一个环境容器不存在，同时启动两个环境"
                                        docker compose up -d app-blue app-green
                                    else
                                        echo "更新目标环境 ${targetEnv}"
                                        docker compose up -d --no-deps --force-recreate app-${targetEnv}
                                    fi

                                    echo "✅ 已部署到 ${targetEnv}"
ENDSSH
                            """
                        }
                    } catch (Exception e) {
                        error("❌ 部署失败: ${e.message}")
                    }
                }
            }
        }

        stage('健康检查') {
            steps {
                script {
                    echo "========== 健康检查 =========="

                    def maxRetries = 30
                    def retryCount = 0
                    def healthy = false

                    echo "正在等待 ${env.TARGET_ENV} 环境启动..."

                    while (retryCount < maxRetries && !healthy) {
                        try {
                            def response
                            sshagent([SSH_CREDENTIALS_ID]) {
                                response = sh(
                                    script: """
                                        ssh -o StrictHostKeyChecking=no ${DEPLOY_USER}@${DEPLOY_HOST} << 'ENDSSH'
                                            cd ${DEPLOY_PATH}
                                            if [ -f .env ]; then
                                                export \$(grep -v '^#' .env | xargs)
                                            fi
                                            CONTAINER_BLUE=\${CONTAINER_BLUE:-app-blue}
                                            CONTAINER_GREEN=\${CONTAINER_GREEN:-app-green}

                                            if [ "${env.TARGET_ENV}" = "blue" ]; then
                                                TARGET_CONTAINER="\$CONTAINER_BLUE"
                                            else
                                                TARGET_CONTAINER="\$CONTAINER_GREEN"
                                            fi

                                            docker exec \$TARGET_CONTAINER curl -sf http://localhost:3000/api/status
ENDSSH
                                    """,
                                    returnStatus: true
                                )
                            }

                            if (response == 0) {
                                healthy = true
                                echo "✅ ${env.TARGET_ENV} 环境健康检查通过!"
                            }
                        } catch (Exception e) {
                            // 忽略异常，继续重试
                        }

                        if (!healthy) {
                            retryCount++
                            echo "健康检查第 ${retryCount}/${maxRetries} 次失败，正在重试..."
                            sleep(time: 5, unit: 'SECONDS')
                        }
                    }

                    if (!healthy) {
                        error("❌ 健康检查失败，已重试 ${maxRetries} 次")
                    }
                }
            }
        }

        stage('灰度发布') {
            when {
                expression {
                    params.DEPLOY_MODE == 'canary' &&
                    env.CURRENT_ENV != 'none' &&
                    !params.IS_ROLLBACK
                }
            }
            steps {
                script {
                    echo "========== 灰度发布 =========="

                    def canarySteps = params.CANARY_PERCENTAGE.split(',').collect { it.trim().toInteger() }
                    def waitTime = params.CANARY_WAIT_TIME.toInteger()

                    echo "开始灰度发布，流量阶梯: ${canarySteps}"

                    for (int i = 0; i < canarySteps.size(); i++) {
                        def percentage = canarySteps[i]

                        // 跳过最后的 100%，留给流量切换阶段
                        if (percentage == 100 && !params.AUTO_PROMOTE) {
                            echo "灰度流量已达 ${canarySteps[i-1]}%，等待手动确认提升到 100%..."
                            input message: "确认提升到 100%?", ok: "确认"
                        }

                        if (percentage < 100) {
                            echo "正在设置灰度流量为 ${percentage}%"

                            try {
                                sshagent([SSH_CREDENTIALS_ID]) {
                                    sh """
                                        ssh -o StrictHostKeyChecking=no ${DEPLOY_USER}@${DEPLOY_HOST} \
                                        '${DEPLOY_PATH}/scripts/set-canary-weight.sh ${env.CURRENT_ENV} ${env.TARGET_ENV} ${percentage}'
                                    """
                                }
                            } catch (Exception e) {
                                error("❌ 设置灰度流量失败: ${e.message}")
                            }

                            // 等待并监控
                            echo "等待 ${waitTime} 秒并监控指标..."
                            sleep(time: waitTime, unit: 'SECONDS')

                            // 验证灰度环境健康状态
                            def healthCheck
                            sshagent([SSH_CREDENTIALS_ID]) {
                                healthCheck = sh(
                                    script: """
                                        ssh -o StrictHostKeyChecking=no ${DEPLOY_USER}@${DEPLOY_HOST} \
                                        '${DEPLOY_PATH}/scripts/check-canary-health.sh ${env.TARGET_ENV}'
                                    """,
                                    returnStatus: true
                                )
                            }

                            if (healthCheck != 0) {
                                echo "❌ 灰度健康检查在 ${percentage}% 时失败! 正在回滚..."
                                rollbackTraffic()
                                error("灰度发布在 ${percentage}% 时失败")
                            }

                            echo "✅ 灰度 ${percentage}% - 健康检查通过"
                        }
                    }

                    echo "✅ 灰度发布成功，准备全量切换"
                }
            }
        }

        stage('流量切换') {
            steps {
                script {
                    echo "========== 流量切换 =========="
                    echo "正在将流量从 ${env.CURRENT_ENV} 切换到 ${env.TARGET_ENV}"

                    try {
                        sshagent([SSH_CREDENTIALS_ID]) {
                            sh """
                                ssh -o StrictHostKeyChecking=no ${DEPLOY_USER}@${DEPLOY_HOST} << 'ENDSSH'
                                    # 使用切换脚本 (100% 流量)
                                    ${DEPLOY_PATH}/scripts/switch-traffic.sh ${env.TARGET_ENV}

                                    # 记录当前活跃环境
                                    echo "${env.TARGET_ENV}" > ${DEPLOY_PATH}/.active_env

                                    echo "✅ 流量已切换到 ${env.TARGET_ENV}"
ENDSSH
                            """
                        }
                    } catch (Exception e) {
                        error("❌ 流量切换失败: ${e.message}")
                    }
                }
            }
        }
    }

    post {
        success {
            script {
                echo "✅ 部署成功! ${env.TARGET_ENV} 环境已激活，版本: ${params.IMAGE_TAG}"
                sendFeishuNotification('success', '部署成功')
            }
        }

        failure {
            script {
                echo "❌ 部署失败! 正在回滚..."
                rollbackTraffic()
                sendFeishuNotification('failure', '部署失败')
            }
        }

        always {
            script {
                // 清理本地 Docker 镜像缓存
                sh """
                    docker images ${ACR_REGISTRY}/${APP_NAME} --format '{{.Tag}}' | tail -n +5 | xargs -r -I {} docker rmi ${ACR_REGISTRY}/${APP_NAME}:{} || true
                """
            }
        }
    }
}

// ============================================
// 函数：回滚流量
// ============================================
def rollbackTraffic() {
    if (env.CURRENT_ENV && env.TARGET_ENV && env.CURRENT_ENV != 'none') {
        try {
            echo "正在回滚流量到 ${env.CURRENT_ENV}..."

            sshagent([SSH_CREDENTIALS_ID]) {
                sh """
                    ssh -o StrictHostKeyChecking=no ${DEPLOY_USER}@${DEPLOY_HOST} << 'ENDSSH'
                        # 重置灰度流量
                        ${DEPLOY_PATH}/scripts/set-canary-weight.sh ${env.CURRENT_ENV} ${env.TARGET_ENV} 0 2>/dev/null || true

                        # 切换回原环境
                        ${DEPLOY_PATH}/scripts/switch-traffic.sh ${env.CURRENT_ENV}

                        # 恢复活跃环境标记
                        echo "${env.CURRENT_ENV}" > ${DEPLOY_PATH}/.active_env

                        echo "✅ 已回滚到 ${env.CURRENT_ENV}"
ENDSSH
                """
            }
        } catch (Exception e) {
            echo "⚠️ 回滚失败: ${e.message}"
        }
    } else {
        echo "⚠️ 无法回滚：当前环境信息不完整"
    }
}

// ============================================
// 函数：发送飞书通知
// ============================================
def sendFeishuNotification(String status, String title) {
    def projectName = env.PROJECT_NAME ?: env.APP_NAME ?: 'N/A'
    def deployEnv = env.TARGET_ENV ?: 'N/A'
    def imageTag = params.IMAGE_TAG ?: 'N/A'
    def commitMsg = (params.GIT_COMMIT_MSG ?: 'N/A')
        .replace('\\', '\\\\')
        .replace('"', '\\"')
        .replace('\n', '\\n')
        .replace('\r', '')
    def deployMode = params.DEPLOY_MODE ?: 'N/A'
    def buildNumberFromCI = params.BUILD_NUMBER_FROM_CI ?: 'N/A'

    def color = (status == 'success') ? 'green' : 'red'
    def emoji = (status == 'success') ? '✅' : '❌'
    def buttonType = (status == 'success') ? 'default' : 'danger'
    def buttonText = (status == 'success') ? '查看部署详情' : '查看失败日志'
    def buttonUrl = (status == 'success') ? env.BUILD_URL : "${env.BUILD_URL}console"

    def statusText = (status == 'success') ? '部署成功' : "部署失败，已自动回滚到 ${env.CURRENT_ENV}"

    def message = """
    {
        "msg_type": "interactive",
        "card": {
            "header": {
                "title": {
                    "tag": "plain_text",
                    "content": "${emoji} ${title}"
                },
                "template": "${color}"
            },
            "elements": [
                {
                    "tag": "div",
                    "fields": [
                        {
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**项目名称:**\\n${projectName}"
                            }
                        },
                        {
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**CI 构建号:**\\n#${buildNumberFromCI}"
                            }
                        },
                        {
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**部署环境:**\\n${deployEnv}"
                            }
                        },
                        {
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**镜像版本:**\\n${imageTag}"
                            }
                        },
                        {
                            "is_short": false,
                            "text": {
                                "tag": "lark_md",
                                "content": "**提交信息:**\\n${commitMsg}"
                            }
                        },
                        {
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**部署模式:**\\n${deployMode}"
                            }
                        },
                        {
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**部署时长:**\\n${currentBuild.durationString.replace(' and counting', '')}"
                            }
                        },
                        {
                            "is_short": false,
                            "text": {
                                "tag": "lark_md",
                                "content": "**状态:**\\n${statusText}"
                            }
                        }
                    ]
                },
                {
                    "tag": "action",
                    "actions": [
                        {
                            "tag": "button",
                            "text": {
                                "tag": "plain_text",
                                "content": "${buttonText}"
                            },
                            "type": "${buttonType}",
                            "url": "${buttonUrl}"
                        }
                    ]
                }
            ]
        }
    }
    """

    try {
        sh """
            curl -X POST '${env.FEISHU_WEBHOOK}' \\
                -H 'Content-Type: application/json' \\
                -d '${message}'
        """
    } catch (Exception e) {
        echo "飞书通知发送失败: ${e.message}"
    }
}
