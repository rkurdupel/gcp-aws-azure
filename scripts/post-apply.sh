#!/usr/bin/env bash
set -euo pipefail

# find root of the project
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
mkdir -p "${ANSIBLE_DIR}"

cd "${REPO_ROOT}/terraform"

# - raw ansible_inventory - get the inventory text (-raw - plain text)
# > redirect output to file
# save to inventory.cloud
terraform output -raw ansible_inventory > "${ANSIBLE_DIR}/inventory.cloud"


# instead of ssh -i ~/.ssh/id_ed25519 rkurdupel@3.72.18.80 / ssh -i ~/.ssh/id_ed25519 -J rkurdupel@3.72.18.80 rkurdupel@10.10.0.11
# ssh coinops-bastion / coinops-db
# coinops-db => hostname check from output
echo "Wrote: ${ANSIBLE_DIR}/inventory.cloud"
cat "${ANSIBLE_DIR}/inventory.cloud"

SSH_CONFIG_OUT="${HOME}/.ssh/coinops-aws.generated"
terraform output -raw ssh_config > "${SSH_CONFIG_OUT}"
echo "Wrote: $SSH_CONFIG_OUT"


# every time ssh (ssh coinops-bastion) ssh checks config and matches name with hostname (3.72.18.80)
SSH_INCLUDE="Include $SSH_CONFIG_OUT"

# check if ssh_include line exists 
if ! grep -qF "$SSH_INCLUDE" "$HOME/.ssh/config" 2>/dev/null; then
  # add to file and save to temp file
  echo "$SSH_INCLUDE" | cat - "$HOME/.ssh/config" > /tmp/ssh_config_tmp
  # replace old config with new
  mv /tmp/ssh_config_tmp "$HOME/.ssh/config"
  echo "Added SSH include to ~/.ssh/config"
fi

# clear old host keys after VM recreation
ssh-keygen -R 10.10.1.12 2>/dev/null || true
ssh-keygen -R 10.10.1.13 2>/dev/null || true
ssh-keygen -R 10.10.1.11 2>/dev/null || true
ssh-keygen -R 10.10.0.10 2>/dev/null || true


echo ""
echo "=== Done ==="
echo "Bastion IP: $(terraform output -raw bastion_public_ip)"
echo ""
echo "Test SSH:"
echo "  ssh coinops-bastion"
echo "  ssh coinops-db"
echo "  ssh coinops-app-1"
echo "  ssh coinops-app-2"
echo ""
echo "Run Ansible:"
echo "  ansible-playbook -i ansible/inventory.cloud ansible/cloud-provision.yml"