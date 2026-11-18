
pipeline {
    agent any

    options {
        disableConcurrentBuilds()
    }

    environment {
        IMAGE_NAME = 'yandrapavankishore/online-learning'
        K8S_MASTER = '172.31.32.210'
        K8S_NAMESPACE = 'online-learning'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build Docker Image') {
            steps {
                sh '''
                    docker build -t ${IMAGE_NAME}:${BUILD_NUMBER} ./app
                '''
            }
        }

        stage('Push to Docker Hub') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'dockerhub-creds',
                        usernameVariable: 'DOCKER_USERNAME',
                        passwordVariable: 'DOCKER_PASSWORD'
                    )
                ]) {
                    sh '''
                        set +x
                        echo "$DOCKER_PASSWORD" | docker login \
                          -u "$DOCKER_USERNAME" --password-stdin

                        docker push ${IMAGE_NAME}:${BUILD_NUMBER}
                        docker logout
                    '''
                }
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                sh '''
                    ssh -o BatchMode=yes \
                      -o StrictHostKeyChecking=yes \
                      ubuntu@${K8S_MASTER} \
                      "kubectl -n ${K8S_NAMESPACE} \
                      set image deployment/online-learning \
                      online-learning=${IMAGE_NAME}:${BUILD_NUMBER}"
                '''
            }
        }

        stage('Verify Deployment') {
            steps {
                sh '''
                    ssh -o BatchMode=yes \
                      -o StrictHostKeyChecking=yes \
                      ubuntu@${K8S_MASTER} \
                      "kubectl -n ${K8S_NAMESPACE} \
                      rollout status deployment/online-learning \
                      --timeout=180s"
                '''
            }
        }
    }

    post {
        success {
            echo 'Online Learning CI/CD pipeline completed successfully!'
        }
        failure {
            echo 'Pipeline failed. Check the console output.'
        }
    }
}
