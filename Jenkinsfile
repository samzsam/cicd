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
        stage('Git pull') {
            steps {
                sh 'git config pull.rebase true'
		sh 'git checkout dev'	
                sh 'git pull origin dev'
            }
        }
        stage('build dev image') {
            steps {
                sh 'docker build -t webapp-dev:latest ./ '
            }
        }
        stage('Remove Old container') {
	    steps {
                sh 'docker ps -aqf "name=dev-webapp"] && {docker stop dev-webapp; docker system prune -f;} || echo 0'
            }
        }
 	stage('Deploy dev webapp') {
            steps {
                sh 'docker run -p 80:80 -d --name dev-webapp webapp-dev:latest'
            }
        }


   }
}
