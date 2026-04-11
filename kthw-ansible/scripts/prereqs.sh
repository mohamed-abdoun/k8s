#!/usr/bin/env bash
# prereqs.sh – Install all host-side prerequisites for the k8s-hardway automation.
#
# Supported host OS: Ubuntu 22.04 / 24.04 (apt-based).
# Run as a regular user with sudo rights.
#
# Usage:
#   ./scripts/prereqs.sh            # auto-detect provider from config/cluster.yml
#   ./scripts/prereqs.sh virtualbox # force VirtualBox + Vagrant prerequisites
#   ./scripts/prereqs.sh kvm        # force KVM + Terraform prerequisites

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/config/cluster.yml"

# ── Colour helpers ────────────────────────────────────────────────────────────
log()     { echo -e "\033[1;32m[prereqs]\033[0m $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die()     { err "$*"; exit 1; }
section() { echo -e "\n\033[1;36m══ $* ══\033[0m"; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] && die "Run as a normal user with sudo rights, not as root."
command -v apt-get &>/dev/null || die "This script requires an apt-based Linux distro (Ubuntu 22.04+)."

# ── Architecture ──────────────────────────────────────────────────────────────
host_uname=$(uname -m)
case "${host_uname}" in
  x86_64)        HOST_ARCH="amd64" ; DEB_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ; DEB_ARCH="arm64" ;;
  *) die "Unsupported architecture: ${host_uname}" ;;
esac
log "Host architecture: ${HOST_ARCH}"

# ── Provider detection ────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
  PROVIDER="$1"
else
  if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
    PROVIDER=$(python3 - "${CONFIG}" <<'EOF'
import sys, yaml
with open(sys.argv[1]) as f:
    print(yaml.safe_load(f)['provider'])
EOF
    )
  else
    warn "python3-yaml not yet installed; defaulting to 'kvm'. Pass provider as arg to override."
    PROVIDER="kvm"
  fi
fi
log "Provider: ${PROVIDER}"

if [[ "${HOST_ARCH}" == "arm64" && "${PROVIDER}" == "virtualbox" ]]; then
  warn "VirtualBox on ARM Linux is not officially supported."
  warn "Consider switching to provider: kvm in config/cluster.yml."
  warn "Continuing anyway (may work on Apple Silicon via VirtualBox 7.1+)."
fi

# ── System update ─────────────────────────────────────────────────────────────
section "System update"
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

# ── Common dependencies ───────────────────────────────────────────────────────
section "Common packages"
sudo apt-get install -y -qq \
  python3 \
  python3-pip \
  python3-yaml \
  python3-venv \
  git \
  curl \
  wget \
  openssl \
  tar \
  jq \
  gnupg \
  lsb-release \
  ca-certificates \
  software-properties-common \
  apt-transport-https

# ── SSH key ───────────────────────────────────────────────────────────────────
section "SSH key"
SSH_KEY="${HOME}/.ssh/id_rsa"
if [[ ! -f "${SSH_KEY}" ]]; then
  log "No SSH key found at ${SSH_KEY} – generating a new one …"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY}" -N "" -C "k8s-hardway-$(hostname)"
  log "Generated ${SSH_KEY} and ${SSH_KEY}.pub"
else
  log "SSH key already exists at ${SSH_KEY}"
fi

# ── Ansible ───────────────────────────────────────────────────────────────────
section "Ansible"
if ! command -v ansible-playbook &>/dev/null; then
  # Use the official PPA for the latest stable Ansible on Ubuntu
  sudo apt-get install -y -qq pipx
  pipx install --include-deps ansible
  pipx ensurepath
  # Make available in current shell immediately
  export PATH="${HOME}/.local/bin:${PATH}"
  log "Ansible installed via pipx"
else
  log "Ansible already installed: $(ansible --version | head -1)"
fi

section "Ansible collections"
ansible-galaxy collection install \
  community.general \
  ansible.posix \
  --ignore-errors \
  2>/dev/null || true
log "Ansible collections installed."

# ═══════════════════════════════════════════════════════════════════════════════
# Provider-specific prerequisites
# ═══════════════════════════════════════════════════════════════════════════════

install_hashicorp_repo() {
  # Add HashiCorp apt repository (used for both Vagrant and Terraform)
  if [[ ! -f /etc/apt/sources.list.d/hashicorp.list ]]; then
    log "Adding HashiCorp apt repository …"
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
      | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=${DEB_ARCH} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    sudo apt-get update -qq
  else
    log "HashiCorp repository already configured."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
if [[ "${PROVIDER}" == "virtualbox" ]]; then

  section "VirtualBox"
  if ! command -v VBoxManage &>/dev/null; then
    # Official Oracle VirtualBox repository
    curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc \
      | sudo gpg --dearmor -o /usr/share/keyrings/oracle-virtualbox.gpg
    echo "deb [arch=${DEB_ARCH} signed-by=/usr/share/keyrings/oracle-virtualbox.gpg] \
https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" \
      | sudo tee /etc/apt/sources.list.d/virtualbox.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq virtualbox-7.1
    log "VirtualBox 7.1 installed."
  else
    log "VirtualBox already installed: $(VBoxManage --version)"
  fi

  section "Vagrant"
  if ! command -v vagrant &>/dev/null; then
    install_hashicorp_repo
    sudo apt-get install -y -qq vagrant
    log "Vagrant installed: $(vagrant --version)"
  else
    log "Vagrant already installed: $(vagrant --version)"
  fi

  section "Vagrant plugins"
  # vagrant-hostmanager is helpful for /etc/hosts management
  vagrant plugin install vagrant-hostmanager 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
elif [[ "${PROVIDER}" == "kvm" ]]; then

  section "KVM / QEMU / libvirt"
  sudo apt-get install -y -qq \
    qemu-kvm \
    qemu-utils \
    libvirt-daemon-system \
    libvirt-clients \
    libvirt-dev \
    bridge-utils \
    virt-manager \
    cpu-checker \
    genisoimage \
    cloud-image-utils

  # Enable and start libvirtd
  sudo systemctl enable --now libvirtd

  # Add current user to libvirt and kvm groups
  for grp in libvirt kvm; do
    if ! id -nG "$USER" | grep -qw "${grp}"; then
      sudo usermod -aG "${grp}" "$USER"
      log "Added ${USER} to group ${grp}"
    fi
  done

  # Verify KVM acceleration is available
  if sudo kvm-ok &>/dev/null; then
    log "KVM hardware acceleration is available."
  else
    warn "KVM hardware acceleration not detected. VMs will be slow (software emulation)."
    warn "Ensure virtualisation is enabled in BIOS/firmware."
  fi

  section "Terraform"
  if ! command -v terraform &>/dev/null; then
    install_hashicorp_repo
    sudo apt-get install -y -qq terraform
    log "Terraform installed: $(terraform --version | head -1)"
  else
    log "Terraform already installed: $(terraform --version | head -1)"
  fi

  section "Terraform libvirt provider"
  # Ensure the provider can be downloaded (pre-init is optional; terraform init handles it)
  log "Provider dmacvicar/libvirt will be fetched automatically on 'terraform init'."

else
  die "Unknown provider '${PROVIDER}'. Use 'virtualbox' or 'kvm'."
fi

# ── kubectl (optional, for local cluster access) ──────────────────────────────
section "kubectl (local cluster access)"
KUBECTL_VERSION=$(python3 - "${CONFIG}" <<'EOF'
import sys, yaml
with open(sys.argv[1]) as f:
    print(yaml.safe_load(f)['cluster']['kubernetes_version'])
EOF
)

if ! command -v kubectl &>/dev/null; then
  log "Downloading kubectl ${KUBECTL_VERSION} …"
  curl -fsSL "https://dl.k8s.io/${KUBECTL_VERSION}/bin/linux/${HOST_ARCH}/kubectl" \
    -o /tmp/kubectl
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
  log "kubectl installed."
else
  log "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Done"
echo ""
echo "  All prerequisites installed for provider '${PROVIDER}' on ${HOST_ARCH}."
echo ""
if id -nG "$USER" | grep -qw "libvirt" 2>/dev/null; then
  echo "  NOTE: You were added to the 'libvirt' and 'kvm' groups."
  echo "        Log out and back in (or run 'newgrp libvirt') for group changes to take effect."
  echo ""
fi
echo "  Next steps:"
echo "    1. Edit  config/cluster.yml  (adjust node counts, IPs, provider)"
echo "    2. Run   ./scripts/up.sh"
echo ""
echo "  To access the cluster after deployment:"
echo "    export KUBECONFIG=${REPO_ROOT}/pki/admin.kubeconfig"
echo "    kubectl get nodes"
echo ""
