#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<USAGE
Usage: ./scripts/lab.sh <command>

Commands:
  apply    terraform apply + generate SSH config + inventory
  deploy   ansible provision + deploy
  full     apply + deploy (full pipeline)
  verify   run failover verification
USAGE
}

terraform_apply() {
    echo ">>> Terraform apply..."
    cd "$REPO_ROOT/terraform"
    terraform init
    terraform apply
    cd "$REPO_ROOT"
    ./scripts/post-apply.sh
}

ansible_deploy() {
    echo ">>> Ansible deploy..."
    cd "$REPO_ROOT"
    source .env
    ansible-playbook -i ansible/inventory.cloud ansible/cloud-provision.yml
    ansible-playbook -i ansible/inventory.cloud ansible/cloud-deploy.yml
}

cmd="${1:-}"
case "$cmd" in
    apply)
        terraform_apply
        ;;
    deploy)
        ansible_deploy
        ;;
    full)
        terraform_apply
        ansible_deploy
        ;;
    verify)
        bash "$REPO_ROOT/scripts/verify_failover.sh"
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        echo "Unknown command: $cmd"
        usage
        exit 1
        ;;
esac
    