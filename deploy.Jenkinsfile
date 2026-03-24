// ============================================
// Deploy Job - 单服务部署
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
    }

    stages {
        stage('参数校验') {
            steps {
                script {
                    echo "========== 参数校验 =========="

                    if (!params.IMAGE_TAG || params.IMAGE_TAG.trim() == '') {
                        error("❌ IMAGE_TAG 参数为空！此参数必须由 Build Job 自动传递，禁止手动触发此 Job。")
                    }

                    if (params.IMAGE_TAG == 'latest' || params.IMAGE_TAG == 'stable') {
                        error("❌ 禁止使用 'latest' 或 'stable' 作为镜像标签！请使用具体版本号。")
                    }

                    if (!params.IMAGE_TAG.matches(/^v\d{8}$/)) {
                        error("❌ IMAGE_TAG 格式不正确！期望格式: v20260304")
                    }

                    echo "✅ IMAGE_TAG 校验通过: ${params.IMAGE_TAG}"
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

        stage('部署服务') {
            steps {
                script {
                    echo "========== 部署服务 =========="
                    echo "正在部署镜像: ${ACR_REGISTRY}/${APP_NAME}:${params.IMAGE_TAG}"

                    try {
                        sshagent([SSH_CREDENTIALS_ID]) {
                            sh """
                                ssh -o StrictHostKeyChecking=no ${DEPLOY_USER}@${DEPLOY_HOST} << 'ENDSSH'
                                    cd ${DEPLOY_PATH}

                                    # 登录 ACR
                                    echo '${ACR_CREDENTIALS_PSW}' | docker login ${ACR_REGISTRY} -u ${ACR_CREDENTIALS_USR} --password-stdin

                                    # 更新 .env 中的 IMAGE_TAG
                                    if grep -q "^IMAGE_TAG=" .env; then
                                        sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${params.IMAGE_TAG}|" .env
                                    else
                                        echo "IMAGE_TAG=${params.IMAGE_TAG}" >> .env
                                    fi

                                    export ACR_REGISTRY="${ACR_REGISTRY}"
                                    export APP_NAME="${APP_NAME}"
                                    export IMAGE_TAG="${params.IMAGE_TAG}"

                                    # 拉取新镜像并重启服务
                                    docker compose pull app
                                    docker compose up -d --force-recreate app

                                    echo "✅ 服务已更新，镜像: ${params.IMAGE_TAG}"
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

                    echo "正在等待服务启动..."

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
                                            CONTAINER_NAME=\${CONTAINER_NAME:-app}
                                            docker exec \$CONTAINER_NAME curl -sf http://localhost:3000/api/status
ENDSSH
                                    """,
                                    returnStatus: true
                                )
                            }

                            if (response == 0) {
                                healthy = true
                                echo "✅ 健康检查通过!"
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
                        error("❌ 健康检查失败，已重试 ${maxRetries} 次，请手动检查服务状态")
                    }
                }
            }
        }
    }

    post {
        success {
            script {
                echo "✅ 部署成功! 版本: ${params.IMAGE_TAG}"
                sendFeishuNotification('success', '部署成功')
            }
        }

        failure {
            script {
                echo "❌ 部署失败!"
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
// 函数：发送飞书通知
// ============================================
def sendFeishuNotification(String status, String title) {
    def projectName = env.PROJECT_NAME ?: env.APP_NAME ?: 'N/A'
    def imageTag = params.IMAGE_TAG ?: 'N/A'
    def commitMsg = (params.GIT_COMMIT_MSG ?: 'N/A')
        .replace('\\', '\\\\')
        .replace('"', '\\"')
        .replace('\n', '\\n')
        .replace('\r', '')
    def buildNumberFromCI = params.BUILD_NUMBER_FROM_CI ?: 'N/A'

    def color = (status == 'success') ? 'green' : 'red'
    def emoji = (status == 'success') ? '✅' : '❌'
    def buttonType = (status == 'success') ? 'default' : 'danger'
    def buttonText = (status == 'success') ? '查看部署详情' : '查看失败日志'
    def buttonUrl = (status == 'success') ? env.BUILD_URL : "${env.BUILD_URL}console"

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
                                "content": "**部署时长:**\\n${currentBuild.durationString.replace(' and counting', '')}"
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
