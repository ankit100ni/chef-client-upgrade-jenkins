pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()
  }

  parameters {
    text(
      name: 'NODE_LIST',
      defaultValue: '',
      description: 'Chef node names to process — one per line. Required.'
    )
    string(
      name: 'UPGRADE_TAG',
      defaultValue: 'upgrade19',
      description: 'Tag to apply to each node (e.g. upgrade19, upgrade21)'
    )
    string(
      name: 'BOOTSTRAP_ROLE',
      defaultValue: 'role[chef_upgrade_cron]',
      description: 'Bootstrap role to prepend to each node run list'
    )
    string(
      name: 'MAX_PARALLEL',
      defaultValue: '20',
      description: 'Max concurrent knife calls'
    )
    booleanParam(
      name: 'DRY_RUN',
      defaultValue: false,
      description: 'If true, print commands without executing live knife mutations'
    )
    string(
      name: 'CHEF_SERVER_URL',
      defaultValue: '',
      description: 'Chef server URL override — leave blank to use ~/.chef/credentials'
    )
    string(
      name: 'CHEF_CLIENT_NAME',
      defaultValue: '',
      description: 'Chef client name override — leave blank to use ~/.chef/credentials'
    )
    string(
      name: 'CHEF_CLIENT_KEY',
      defaultValue: '',
      description: 'Path to Chef client key file override — leave blank to use ~/.chef/credentials'
    )
  }

  environment {
    REPORTS_DIR = 'reports/raw'
  }

  stages {

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 1 — Precheck: verify tooling and inputs before touching any nodes
    // ─────────────────────────────────────────────────────────────────────────
    stage('Precheck') {
      steps {
        sh '''
          set -euo pipefail
          command -v knife >/dev/null || {
            echo "ERROR: knife not found in PATH. Is Chef Workstation installed?"
            exit 1
          }
          knife --version
        '''
        script {
          if (!params.NODE_LIST?.trim()) {
            error('NODE_LIST parameter is empty. Provide at least one node name.')
          }
          def nodeCount = params.NODE_LIST.trim().split('\n').findAll { it.trim() }.size()
          echo "Nodes to process : ${nodeCount}"
          echo "Upgrade tag      : ${params.UPGRADE_TAG}"
          echo "Bootstrap role   : ${params.BOOTSTRAP_ROLE}"
          echo "Max parallel     : ${params.MAX_PARALLEL}"
          echo "Dry run          : ${params.DRY_RUN}"
        }
        sh 'mkdir -p reports/raw logs'
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 2 — Tag Nodes
    //   Removes conflicting tags, applies UPGRADE_TAG to each node in parallel.
    //   Writes reports/raw/tagged_nodes.json and reports/raw/tag_success.list.
    //   Jenkins env vars (NODE_LIST, UPGRADE_TAG, MAX_PARALLEL, DRY_RUN, etc.)
    //   are inherited by tag_nodes.sh automatically.
    // ─────────────────────────────────────────────────────────────────────────
    stage('Tag Nodes') {
      steps {
        sh 'bash scripts/tag_nodes.sh'
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 3 — Prepend Bootstrap Role
    //   Reads the node list from tag_success.list (Stage 2 handoff file).
    //   Atomically prepends BOOTSTRAP_ROLE to each node's Chef run list.
    //   Writes reports/raw/prepend_role.json.
    // ─────────────────────────────────────────────────────────────────────────
    stage('Prepend Bootstrap Role') {
      steps {
        sh 'TAG_SUCCESS_LIST=reports/raw/tag_success.list bash scripts/prepend_role.sh'
      }
    }

  }

  post {
    always {
      archiveArtifacts artifacts: 'reports/raw/*.json', allowEmptyArchive: true
    }
    success {
      echo '=============================================='
      echo '  PIPELINE SUCCEEDED'
      echo '  All nodes tagged and bootstrap role prepended.'
      echo '=============================================='
    }
    failure {
      echo '=============================================='
      echo '  PIPELINE FAILED'
      echo '  Check the stage logs above for details.'
      echo '  Partial results may be in reports/raw/*.json'
      echo '=============================================='
    }
  }
}
