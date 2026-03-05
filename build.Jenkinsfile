// ============================================
// Build Job - 构建镜像并触发部署
// ============================================
pipeline {
    agent any

    environment {
        // Git 配置
        GIT_REPO_URL = 'https://github.com/dimleap/apiqik-backend.git'
        GIT_CREDENTIALS_ID = 'github-token'

        // ACR 配置
        ACR_REGISTRY = credentials('acr-docker-registry')
        ACR_CREDENTIALS = credentials('acr-docker-password')
        APP_NAME = 'apiqik-backend'
        PROJECT_NAME = 'apiqik-backend'

        // 飞书机器人配置
        FEISHU_WEBHOOK = credentials('feishu-webhook')

        // 镜像标签（格式：v20260304）
        IMAGE_TAG = "v${new Date().format('yyyyMMdd')}"
    }

    parameters {
        // 代码分支选择
        string(
            name: 'GIT_BRANCH',
            defaultValue: 'main',
            description: '要构建的代码分支（例如: main, develop, feature/xxx）'
        )

        // 构建模式选择
        choice(
            name: 'BUILD_MODE',
            choices: ['build_and_deploy', 'deploy_only'],
            description: '构建模式: build_and_deploy=打包镜像并部署, deploy_only=仅部署已有镜像'
        )

        // 手动指定镜像标签（仅在 deploy_only 模式下使用）
        string(
            name: 'MANUAL_IMAGE_TAG',
            defaultValue: '',
            description: '手动指定镜像标签（仅在 deploy_only 模式下生效，格式: v20260304）'
        )

        // 多选部署服务
        booleanParam(
            name: 'DEPLOY_TO_TEST_BACKEND',
            defaultValue: true,
            description: '部署到测试环境-主站'
        )
        booleanParam(
            name: 'DEPLOY_TO_TEST_BACKEND_SOURCE',
            defaultValue: true,
            description: '部署到测试环境-号池'
        )
        booleanParam(
            name: 'DEPLOY_TO_PROD_BACKEND_3000',
            defaultValue: false,
            description: '部署到生产环境-中转站-3000'
        )
        booleanParam(
            name: 'DEPLOY_TO_PROD_BACKEND_3001',
            defaultValue: false,
            description: '部署到生产环境-中转站-3001'
        )
    }

    stages {
        stage('参数校验') {
            steps {
                script {
                    echo "========== 参数校验 =========="
                    echo "构建模式: ${params.BUILD_MODE}"

                    // 如果是 deploy_only 模式，校验 MANUAL_IMAGE_TAG
                    if (params.BUILD_MODE == 'deploy_only') {
                        if (!params.MANUAL_IMAGE_TAG || params.MANUAL_IMAGE_TAG.trim() == '') {
                            error("❌ deploy_only 模式下必须填写 MANUAL_IMAGE_TAG 参数")
                        }

                        // 校验格式
                        if (!params.MANUAL_IMAGE_TAG.matches(/^v\d{8}$/)) {
                            error("❌ MANUAL_IMAGE_TAG 格式不正确！期望格式: v20260304")
                        }

                        // 使用手动指定的标签
                        env.IMAGE_TAG = params.MANUAL_IMAGE_TAG
                        echo "✅ 使用手动指定的镜像标签: ${env.IMAGE_TAG}"

                        // 设置默认的 Git 信息（因为不拉取代码）
                        env.GIT_COMMIT = 'N/A'
                        env.GIT_COMMIT_MSG = '手动触发部署'
                    } else {
                        echo "✅ build_and_deploy 模式，将自动生成镜像标签"
                    }
                }
            }
        }

        stage('拉取代码') {
            when {
                expression { params.BUILD_MODE == 'build_and_deploy' }
            }
            steps {
                script {
                    echo "正在从分支 ${params.GIT_BRANCH} 拉取代码..."

                    def scmVars = checkout([
                        $class: 'GitSCM',
                        branches: [[name: "*/${params.GIT_BRANCH}"]],
                        userRemoteConfigs: [[
                            url: env.GIT_REPO_URL,
                            credentialsId: env.GIT_CREDENTIALS_ID
                        ]]
                    ])

                    env.GIT_COMMIT = scmVars.GIT_COMMIT
                    env.GIT_COMMIT_MSG = sh(
                        script: 'git log -1 --pretty=%B',
                        returnStdout: true
                    ).trim()

                    // 重新计算 IMAGE_TAG（格式：v20260304）
                    env.IMAGE_TAG = "v${new Date().format('yyyyMMdd')}"

                    echo "已拉取分支: ${params.GIT_BRANCH}"
                    echo "提交信息: ${env.GIT_COMMIT_MSG}"
                    echo "提交哈希: ${env.GIT_COMMIT}"
                    echo "镜像标签: ${env.IMAGE_TAG}"
                }
            }
        }

        stage('构建镜像') {
            when {
                expression { params.BUILD_MODE == 'build_and_deploy' }
            }
            steps {
                script {
                    echo "正在构建 Docker 镜像: ${ACR_REGISTRY}/${APP_NAME}:${IMAGE_TAG}"

                    try {
                        sh """
                            docker build \
                                --build-arg BUILD_DATE=\$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
                                --build-arg VCS_REF=${env.GIT_COMMIT} \
                                --build-arg VERSION=${env.IMAGE_TAG} \
                                -t ${ACR_REGISTRY}/${APP_NAME}:${IMAGE_TAG} \
                                .
                        """
                    } catch (Exception e) {
                        error("Docker 镜像构建失败: ${e.message}")
                    }
                }
            }
        }

        stage('推送镜像') {
            when {
                expression { params.BUILD_MODE == 'build_and_deploy' }
            }
            steps {
                script {
                    echo "正在推送镜像到阿里云 ACR"

                    try {
                        sh """
                            echo "${ACR_CREDENTIALS_PSW}" | docker login "${ACR_REGISTRY}" -u "${ACR_CREDENTIALS_USR}" --password-stdin
                            docker push "${ACR_REGISTRY}/${APP_NAME}:${IMAGE_TAG}"
                        """

                        // 验证镜像已成功推送
                        def manifestCheck = sh(
                            script: """
                                echo "${ACR_CREDENTIALS_PSW}" | docker login "${ACR_REGISTRY}" -u "${ACR_CREDENTIALS_USR}" --password-stdin
                                docker manifest inspect "${ACR_REGISTRY}/${APP_NAME}:${IMAGE_TAG}"
                            """,
                            returnStatus: true
                        )

                        if (manifestCheck != 0) {
                            error("镜像推送验证失败，镜像可能未成功上传到 ACR")
                        }

                        echo "✅ 镜像推送成功并已验证: ${IMAGE_TAG}"

                    } catch (Exception e) {
                        error("镜像推送失败: ${e.message}")
                    }
                }
            }
        }

        stage('镜像存在性校验') {
            when {
                expression { params.BUILD_MODE == 'deploy_only' }
            }
            steps {
                script {
                    echo "========== 镜像存在性校验 =========="

                    def fullImage = "${ACR_REGISTRY}/${APP_NAME}:${env.IMAGE_TAG}"
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
                        error("❌ 镜像校验失败: ${e.message}\n请确认镜像标签是否正确。")
                    }
                }
            }
        }

        stage('触发部署') {
            steps {
                script {
                    def deployJobs = []

                    // 根据用户选择构建部署任务列表
                    if (params.DEPLOY_TO_TEST_BACKEND) {
                        deployJobs.add([
                            jobName: '测试环境/deploy-to-test-backend',
                            envName: '测试环境-中转站'
                        ])
                    }
                    if (params.DEPLOY_TO_TEST_BACKEND_SOURCE) {
                        deployJobs.add([
                            jobName: '测试环境/deploy-to-test-backend-source',
                            envName: '测试环境-号池'
                        ])
                    }
                    if (params.DEPLOY_TO_PROD_BACKEND_3000) {
                        deployJobs.add([
                            jobName: '生产环境/deploy-to-prod-backend-3000',
                            envName: '生产环境-中转站-3000'
                        ])
                    }
                    if (params.DEPLOY_TO_PROD_BACKEND_3001) {
                        deployJobs.add([
                            jobName: '生产环境/deploy-to-prod-backend-3001',
                            envName: '生产环境-中转站-3001'
                        ])
                    }

                    if (deployJobs.isEmpty()) {
                        echo "⚠️ 未选择任何部署环境，跳过部署阶段"
                        return
                    }

                    echo "准备触发 ${deployJobs.size()} 个部署任务..."

                    // 并行触发所有部署任务
                    def parallelDeployments = [:]

                    deployJobs.each { job ->
                        parallelDeployments[job.envName] = {
                            echo "正在触发 ${job.envName} 部署..."

                            try {
                                build(
                                    job: job.jobName,
                                    parameters: [
                                        string(name: 'IMAGE_TAG', value: env.IMAGE_TAG),
                                        string(name: 'GIT_COMMIT', value: env.GIT_COMMIT),
                                        string(name: 'GIT_COMMIT_MSG', value: env.GIT_COMMIT_MSG),
                                        string(name: 'BUILD_NUMBER_FROM_CI', value: env.BUILD_NUMBER)
                                    ],
                                    wait: false  // 异步触发，不等待完成
                                )
                                echo "✅ ${job.envName} 部署任务已触发"
                            } catch (Exception e) {
                                echo "❌ ${job.envName} 部署任务触发失败: ${e.message}"
                            }
                        }
                    }

                    parallel parallelDeployments
                }
            }
        }
    }

    post {
        success {
            script {
                def mode = params.BUILD_MODE == 'build_and_deploy' ? '构建+部署' : '仅部署'
                sendFeishuNotification('success', "${mode}成功")
            }
        }

        failure {
            script {
                def mode = params.BUILD_MODE == 'build_and_deploy' ? '构建+部署' : '仅部署'
                sendFeishuNotification('failure', "${mode}失败")
            }
        }

        always {
            script {
                // 仅在 build_and_deploy 模式下清理镜像
                if (params.BUILD_MODE == 'build_and_deploy') {
                    sh """
                        docker images ${ACR_REGISTRY}/${APP_NAME} --format '{{.Tag}}' | tail -n +4 | xargs -r -I {} docker rmi ${ACR_REGISTRY}/${APP_NAME}:{} || true
                    """
                }
            }
        }
    }
}

// ============================================
// 函数：发送飞书通知
// ============================================
def sendFeishuNotification(String status, String title) {
    def projectName = env.PROJECT_NAME ?: env.APP_NAME ?: 'N/A'
    def imageTag = env.IMAGE_TAG ?: 'N/A'
    def buildMode = params.BUILD_MODE == 'build_and_deploy' ? '构建+部署' : '仅部署'
    def commitMsg = (env.GIT_COMMIT_MSG ?: 'N/A')
        .replace('\\', '\\\\')
        .replace('"', '\\"')
        .replace('\n', '\\n')
        .replace('\r', '')

    def deployTargets = []
    if (params.DEPLOY_TO_TEST_BACKEND) deployTargets.add('测试环境-中转站')
    if (params.DEPLOY_TO_TEST_BACKEND_SOURCE) deployTargets.add('测试环境-号池')
    if (params.DEPLOY_TO_PROD_BACKEND_3000) deployTargets.add('生产环境-中转站-3000')
    if (params.DEPLOY_TO_PROD_BACKEND_3001) deployTargets.add('生产环境-中转站-3001')
    def deployTargetsStr = deployTargets.isEmpty() ? '无' : deployTargets.join(', ')

    def color = (status == 'success') ? 'green' : 'red'
    def emoji = (status == 'success') ? '✅' : '❌'
    def buttonType = (status == 'success') ? 'default' : 'danger'
    def buttonText = (status == 'success') ? '查看构建详情' : '查看失败日志'
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
                                "content": "**构建编号:**\\n#${BUILD_NUMBER}"
                            }
                        },
                        {
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**构建模式:**\\n${buildMode}"
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
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**部署目标:**\\n${deployTargetsStr}"
                            }
                        },
                        {
                            "is_short": true,
                            "text": {
                                "tag": "lark_md",
                                "content": "**构建时长:**\\n${currentBuild.durationString.replace(' and counting', '')}"
                            }
                        },
                        {
                            "is_short": false,
                            "text": {
                                "tag": "lark_md",
                                "content": "**提交信息:**\\n${commitMsg}"
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

    // try {
    //     sh """
    //         curl -X POST '${env.FEISHU_WEBHOOK}' \\
    //             -H 'Content-Type: application/json' \\
    //             -d '${message}'
    //     """
    // } catch (Exception e) {
    //     echo "飞书通知发送失败: ${e.message}"
    // }
}
