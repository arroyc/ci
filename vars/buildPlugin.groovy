#!/usr/bin/env groovy
import com.microsoft.azure.devops.ci.utils

def call() {
    def ciUtils = new com.microsoft.azure.devops.ci.utils()
    testResultFilePatterns = ciUtils.getTestResultFilePatterns()
    ciUtils.loadJobProperties()

    timeout(60) {
        stage('Build') {
            parallel failFast: true,
            Windows: {
                if ( params.run_windows_build_step ) {
                    node('win2016-dev') {
                        checkout scm
                        bat 'mvn clean install package'
                    }
                }
            },
            Linux: {
                node('ubuntu') {
                    checkout scm
                    sh 'mvn clean install package'

                    stash includes: testResultFilePatterns.surefire + ', ' + testResultFilePatterns.findBugs, name: 'test_results'
                    sh 'cp target/*.hpi .'
                    archiveArtifacts '*.hpi'
                }
            }
        }

        if ( params.run_integration_tests ) {
            stage('Integration Tests') {
                ciUtils.runIntegrationTests([
                    [
                        label: "Global Azure (Linux)",
                        node_name: "ubuntu",
                        environment: "az_test_env"
                    ]/*,
                    [
                        label: "Global Azure (Windows)",
                        node_name: "win2016-dev",
                        environment: "az_test_env2"
                    ]*//*,
                    [
                        label: "Mooncake",
                        node_name: "linux-mooncake",
                        environment: "az_test_mooncake"
                    ]*/
                ])
            }
        }

        node('linux-dev') {
            stage ('Publish Test Results') {
                sh 'rm -rf *'
                unstash 'test_results'
                unstash 'integration_test_results'

                junit testResultFilePatterns.surefire + ', ' + testResultFilePatterns.failsafe
                step([$class: 'FindBugsPublisher', canComputeNew: false, defaultEncoding: '', excludePattern: '', healthy: '', includePattern: '', pattern: testResultFilePatterns.findBugs, unHealthy: ''])
            }
            stage('Upload Bits') {
                build job: 'Upload Bits',
                    parameters: [
                        string(name: 'parent_project', value: "${env.JOB_NAME}"),
                        string(name: 'parent_build_number', value: "${env.BUILD_NUMBER}"),
                        string(name: 'container_name', value: 'devops-jenkins'),
                        string(name: 'artifacts_pattern', value: '*.hpi'),
                        string(name: 'virtual_path', value: "${env.JOB_NAME}/${env.BUILD_NUMBER}")
                    ]
            }
        }

        if ( params.dogfood) {
            stage('Dogfood') {
                build job: 'Dogfood',
                    parameters: [
                        string(name: 'plugin_path', value: "${env.JOB_NAME}/${env.BUILD_NUMBER}"),
                        booleanParam(name: 'run', value: true),
                        string(name: 'container_name', value: 'devops-jenkins')
                    ]
            }
        }
    }
}