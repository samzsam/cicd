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

   }
}
