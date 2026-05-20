pipeline {
    agent any
    environment {
        IMAGE = "registry.tch.internal/app:${GIT_COMMIT}"
    }
    stages {
        stage('Test') {
            steps { sh 'pytest tests/' }
        }
        stage('SAST - SonarQube') {
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh 'mvn sonar:sonar -Dsonar.qualitygate.wait=true'
                }
            }
        }
        stage('Build & Scan') {
            steps {
                sh "docker build -t ${IMAGE} ."
                sh "trivy image --exit-code 1 --severity CRITICAL ${IMAGE}"
            }
        }
        stage('Push') {
            steps {
                sh "docker push ${IMAGE}"
            }
        }
        stage('Deploy Staging') {
            steps {
                sh "helm upgrade --install app ./chart --set image.tag=${GIT_COMMIT} -n staging"
            }
        }
        stage('DAST') {
            steps {
                sh "docker run -t owasp/zap2docker-stable zap-baseline.py -t https://staging.tch.internal -I"
            }
        }
    }
    post {
        failure {
            slackSend channel: '#alerts', message: "Pipeline FAILED: ${JOB_NAME} ${BUILD_URL}"
        }
    }
}
