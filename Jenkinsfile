pipeline {
    agent {label 'awswebserver'}
    stages {
        stage('Checkout') {
            steps {
                checkout([$class: 'GitSCM', branches: [[name: '*/main']], extensions: [], userRemoteConfigs: [[credentialsId: 'samzsam', url: 'https://github.com/samzsam/cicd.git']]])
            }
        }
 	stage('build location') {
            steps {
                sh 'pwd '
            }
        }
        stage('build dev image') {
            steps {
                sh 'docker build -t webapp-dev:latest ./ '
i            }
        }
        stage('Remove Old container') {
            steps {
                sh 'docker stop dev-webapp'
            }
        }
 	stage('Deploy dev webapp') {
            steps {
                sh 'docker run -p 80:80 -d --name dev-webapp webapp-dev:latest'
            }
        }


   }
}
