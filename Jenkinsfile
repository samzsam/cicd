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
            }
        }
        stage('Remove Old container') {
            steps {
                sh '
			if [ ! "$(docker ps -q -f name=dev-webapp)" ]; then
    			if [ "$(docker ps -aq -f status=exited -f name=dev-webapp)" ]; then
        		# cleanup
        		docker rm dev-webapp
    			fi
       		'
        	sh 'docker system prune -f'
            }
        }
 	stage('Deploy dev webapp') {
            steps {
                sh 'docker run -p 80:80 -d --name dev-webapp webapp-dev:latest'
            }
        }


   }
}
