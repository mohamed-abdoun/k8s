#!/usr/bin/env bash
# up.sh – Provision VMs and deploy the Kubernetes cluster.
#
# Usage:
#   ./scripts/up.sh              # provision VMs + full cluster setup
#   ./scripts/up.sh --vms-only   # provision VMs only
#   ./scripts/up.sh --ansible-only  # run Ansible against existing VMs
#   ./scripts/up.sh --playbook control-plane.yml  # run a specific playbook
#   ./scripts/up.sh --destroy    # tear down all VMs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/config/cluster.yml"
ANSIBLE_DIR="${REPO_ROOT}/ansible"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m[up.sh]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "'$cmd' not found in PATH. Please install it."
  done
}

# ── Parse cluster.yml with Python ────────────────────────────────────────────
cfg() {
  python3 - "$CONFIG" "$1" <<'EOF'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
keys = sys.argv[2].split('.')
val = data
for k in keys:
    val = val[k]
print(val)
EOF
}

# ── Architecture detection ────────────────────────────────────────────────────
# Normalise uname -m → amd64 | arm64 (Go/Docker naming convention).
host_uname=$(uname -m)
case "${host_uname}" in
  x86_64)          HOST_ARCH="amd64" ;;
  aarch64|arm64)   HOST_ARCH="arm64" ;;
  *)               die "Unsupported host architecture: ${host_uname}" ;;
esac

cfg_arch=$(cfg arch 2>/dev/null || echo "auto")
if [[ "${cfg_arch}" == "auto" ]]; then
  ARCH="${HOST_ARCH}"
else
  ARCH="${cfg_arch}"
fi
log "Architecture: ${ARCH} (host=${HOST_ARCH}, config=${cfg_arch})"

# Ubuntu 24.04 cloud image URL per arch
case "${ARCH}" in
  amd64) UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
  arm64) UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img" ;;
esac

PROVIDER=$(cfg provider)
log "Provider: ${PROVIDER}"

# ── Argument parsing ──────────────────────────────────────────────────────────
VMS_ONLY=false
ANSIBLE_ONLY=false
DESTROY=false
PLAYBOOK="playbooks/site.yml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vms-only)      VMS_ONLY=true ;;
    --ansible-only)  ANSIBLE_ONLY=true ;;
    --destroy)       DESTROY=true ;;
    --playbook)      PLAYBOOK="playbooks/${2}"; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

# ── Generate terraform.tfvars.json from cluster.yml (KVM only) ───────────────
generate_tfvars() {
  log "Generating terraform/terraform.tfvars.json from cluster.yml …"
  local arch="${ARCH}"
  local image_url="${UBUNTU_IMAGE_URL}"
  python3 - "$CONFIG" "${REPO_ROOT}/terraform/terraform.tfvars.json" "${arch}" "${image_url}" <<'EOF'
import sys, json, yaml

with open(sys.argv[1]) as f:
    c = yaml.safe_load(f)

arch      = sys.argv[3]
image_url = sys.argv[4]
net   = c['network']
nodes = c['nodes']
ssh   = c['ssh']

tfvars = {
    "cluster_name":         c['cluster']['name'],
    "arch":                 arch,
    "ubuntu_image_url":     image_url,
    "subnet":               net['subnet'],
    "lb_last_octet":        net['lb_last_octet'],
    "masters_first_octet":  net['masters_first_octet'],
    "workers_first_octet":  net['workers_first_octet'],
    "masters_count":        nodes['masters']['count'],
    "workers_count":        nodes['workers']['count'],
    "masters_cpus":         nodes['masters']['cpus'],
    "masters_memory":       nodes['masters']['memory'],
    "workers_cpus":         nodes['workers']['cpus'],
    "workers_memory":       nodes['workers']['memory'],
    "lb_cpus":              nodes['loadbalancer']['cpus'],
    "lb_memory":            nodes['loadbalancer']['memory'],
    "ssh_public_key_path":  ssh['public_key'],
}

with open(sys.argv[2], 'w') as f:
    json.dump(tfvars, f, indent=2)

print("Written:", sys.argv[2])
EOF
}

# ── VirtualBox / Vagrant ──────────────────────────────────────────────────────
provision_virtualbox() {
  require vagrant VBoxManage
  log "Starting Vagrant (VirtualBox) …"
  cd "${REPO_ROOT}/vagrant"
  vagrant up --provider=virtualbox
  log "All VMs are up."
}

destroy_virtualbox() {
  require vagrant
  cd "${REPO_ROOT}/vagrant"
  vagrant destroy -f
  log "All VMs destroyed."
}

# ── KVM / Terraform ───────────────────────────────────────────────────────────
provision_kvm() {
  require terraform virsh
  generate_tfvars
  log "Running terraform init + apply …"
  cd "${REPO_ROOT}/terraform"
  terraform init -upgrade
  terraform apply -auto-approve -var-file=terraform.tfvars.json
  log "All VMs are up."
}

destroy_kvm() {
  require terraform
  generate_tfvars
  cd "${REPO_ROOT}/terraform"
  terraform destroy -auto-approve -var-file=terraform.tfvars.json
  log "All VMs destroyed."
}

# ── Wait for SSH on all nodes ─────────────────────────────────────────────────
wait_for_ssh() {
  log "Waiting for SSH to be available on all nodes …"
  require python3
  python3 - "$CONFIG" <<'EOF'
import sys, yaml, socket, time

with open(sys.argv[1]) as f:
    c = yaml.safe_load(f)

net   = c['network']
nodes = c['nodes']
subnet = net['subnet']

ips = [f"{subnet}.{net['lb_last_octet']}"]
for i in range(nodes['masters']['count']):
    ips.append(f"{subnet}.{net['masters_first_octet'] + i}")
for i in range(nodes['workers']['count']):
    ips.append(f"{subnet}.{net['workers_first_octet'] + i}")

deadline = time.time() + 300
for ip in ips:
    sys.stdout.write(f"  Waiting for {ip}:22 … ")
    sys.stdout.flush()
    while time.time() < deadline:
        try:
            s = socket.create_connection((ip, 22), timeout=3)
            s.close()
            print("OK")
            break
        except OSError:
            time.sleep(3)
    else:
        print(f"\nERROR: {ip}:22 not reachable after 5 min", file=sys.stderr)
        sys.exit(1)
EOF
  log "All nodes are SSH-ready."
}

# ── Ansible ───────────────────────────────────────────────────────────────────
run_ansible() {
  require ansible-playbook
  log "Running Ansible playbook: ${PLAYBOOK} …"
  cd "${ANSIBLE_DIR}"
  ansible-playbook "${PLAYBOOK}" "$@"
  log "Ansible run complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────
require python3

if $DESTROY; then
  case "$PROVIDER" in
    virtualbox) destroy_virtualbox ;;
    kvm)        destroy_kvm ;;
    *) die "Unknown provider: ${PROVIDER}" ;;
  esac
  exit 0
fi

if ! $ANSIBLE_ONLY; then
  case "$PROVIDER" in
    virtualbox) provision_virtualbox ;;
    kvm)        provision_kvm ;;
    *) die "Unknown provider: ${PROVIDER}" ;;
  esac
  wait_for_ssh
fi

if ! $VMS_ONLY; then
  run_ansible
fi

log "Done! Your cluster is ready."

# ── Install kubeconfig for the current user ───────────────────────────────────
KUBECONFIG_SRC="${REPO_ROOT}/pki/admin.kubeconfig"
if [[ -f "${KUBECONFIG_SRC}" ]]; then
  mkdir -p "${HOME}/.kube"
  cp "${KUBECONFIG_SRC}" "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  log "kubeconfig installed to ~/.kube/config"
fi

log ""
log "To access the cluster:"
log "  kubectl get nodes"
