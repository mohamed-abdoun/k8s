# Kubernetes the Hard Way — Ansible Automation


A fully automated implementation of *Kubernetes the Hard Way* that provisions real VMs and deploys a production-grade, TLS-secured multi-node Kubernetes cluster from scratch. No kubeadm. No managed services. Every component is downloaded, configured, and wired together by Ansible.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Component Versions](#component-versions)
- [Repository Layout](#repository-layout)
- [Quick Start](#quick-start)
- [Configuration: `config/cluster.yml`](#configuration-configclusteryml)
- [Scripts](#scripts)
  - [`scripts/prereqs.sh`](#scriptsprereqssh)
  - [`scripts/up.sh`](#scriptsupsh)
- [VM Provisioning](#vm-provisioning)
  - [KVM / Terraform](#kvm--terraform)
  - [VirtualBox / Vagrant](#virtualbox--vagrant)
- [Ansible Layer](#ansible-layer)
  - [Dynamic Inventory](#dynamic-inventory-ansibleinventoryinventorypy)
  - [Playbooks](#playbooks)
  - [Roles](#roles)
- [PKI Layout](#pki-layout)
- [Network Layout](#network-layout)
- [Cluster Access](#cluster-access)
- [Day-2 Operations](#day-2-operations)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Host Machine                             │
│                                                                 │
│  config/cluster.yml ──► scripts/up.sh                          │
│                              │                                  │
│               ┌──────────────┴──────────────┐                  │
│               ▼                             ▼                   │
│        KVM / Terraform             VirtualBox / Vagrant         │
│               │                             │                   │
│               └──────────────┬──────────────┘                  │
│                              ▼                                  │
│                     ansible-playbook site.yml                   │
│                              │                                  │
└──────────────────────────────┼──────────────────────────────────┘
                               │ SSH
     ┌─────────────────────────┼──────────────────────────┐
     │  192.168.56.0/24        │                           │
     │                         ▼                           │
     │   ┌─────────────────────────────────────────────┐  │
     │   │           lb  (192.168.56.10)               │  │
     │   │        HAProxy  →  :6443 TCP LB             │  │
     │   └─────────────────────────────────────────────┘  │
     │                                                     │
     │   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │
     │   │  master-1   │ │  master-2   │ │  master-3   │  │
     │   │ .11         │ │ .12         │ │ .13         │  │
     │   │ etcd        │ │ etcd        │ │ etcd        │  │
     │   │ kube-apiserv│ │ kube-apiserv│ │ kube-apiserv│  │
     │   │ kube-sched  │ │ kube-sched  │ │ kube-sched  │  │
     │   │ kube-ctrl-mg│ │ kube-ctrl-mg│ │ kube-ctrl-mg│  │
     │   │ kubelet     │ │ kubelet     │ │ kubelet     │  │
     │   └─────────────┘ └─────────────┘ └─────────────┘  │
     │                                                     │
     │   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │
     │   │  worker-1   │ │  worker-2   │ │  worker-3   │  │
     │   │ .21         │ │ .22         │ │ .23         │  │
     │   │ containerd  │ │ containerd  │ │ containerd  │  │
     │   │ kubelet     │ │ kubelet     │ │ kubelet     │  │
     │   └─────────────┘ └─────────────┘ └─────────────┘  │
     │                                                     │
     └─────────────────────────────────────────────────────┘
```

**Key design decisions:**

- `config/cluster.yml` is the **single source of truth**. Both the VM provisioner (Terraform/Vagrant) and Ansible read it; nothing is duplicated.
- All TLS is generated locally on the Ansible control machine and pushed to nodes. No `cfssl` or `kubeadm` is required — only `openssl`.
- Cilium replaces kube-proxy (`kubeProxyReplacement=true`), handling pod networking and load-balancing entirely in eBPF.
- Worker nodes join via **TLS bootstrap** (token-based), so no kubelet client certificates need to be pre-generated per worker.
- Control-plane masters are brought up **one at a time** (`serial: 1`) to ensure safe etcd leader election.

---

## Component Versions

All versions are set in `config/cluster.yml`:

| Component | Default version |
|---|---|
| Kubernetes | v1.34.2 |
| etcd | v3.6.7 |
| containerd | v2.2.1 |
| CNI plugins | v1.9.0 |
| Cilium | 1.18.5 |
| OS | Ubuntu 24.04 (Noble) |

---

## Repository Layout

```
ansible-samir-kthw/
├── config/
│   └── cluster.yml              # Single source of truth for all settings
│
├── scripts/
│   ├── prereqs.sh               # Install host-side tools (Ansible, Terraform/Vagrant, kubectl)
│   └── up.sh                    # Main entrypoint: provision VMs + run Ansible
│
├── terraform/                   # KVM provider (libvirt)
│   ├── main.tf                  # All libvirt resources (pool, network, VMs)
│   ├── variables.tf             # Input variable declarations
│   ├── outputs.tf               # Exposes lb_ip, master_ips, worker_ips
│   ├── terraform.tfvars.json    # Auto-generated by up.sh from cluster.yml
│   └── cloud-init/
│       ├── user-data.tpl        # Cloud-init user-data (SSH keys, packages, hosts)
│       └── network-config.tpl   # Cloud-init static IP configuration
│
├── vagrant/
│   └── Vagrantfile              # VirtualBox provider; reads cluster.yml directly
│
└── ansible/
    ├── ansible.cfg              # Inventory path, SSH settings, fact caching
    ├── group_vars/
    │   └── all.yml              # Directory paths and certificate validity defaults
    ├── inventory/
    │   └── inventory.py         # Dynamic inventory: reads cluster.yml, emits JSON
    └── playbooks/
        ├── site.yml             # Full cluster deployment (all roles in order)
        ├── pki.yml              # PKI only: regenerate and redistribute certs
        ├── control-plane.yml    # Control-plane only: etcd + HAProxy + API server stack
        └── workers.yml          # Workers only: kubelet + containerd + CNI
    └── roles/
        ├── common/              # Base OS setup applied to every node
        ├── pki/                 # TLS certificate generation and distribution
        ├── etcd/                # etcd cluster setup on masters
        ├── haproxy/             # HAProxy TCP load balancer on lb node
        ├── kube-apiserver/      # kube-apiserver + kubectl binaries
        ├── kube-scheduler/      # kube-scheduler binary and service
        ├── kube-controller-manager/  # kube-controller-manager + bootstrap RBAC
        ├── kubelet/             # containerd + runc + CNI plugins + kubelet
        ├── cilium/              # Cilium CNI installation via cilium CLI
        └── coredns/             # CoreDNS DNS add-on deployment
```

---

## Quick Start

### 1. Choose a provider

Edit `config/cluster.yml` and set `provider`:

```yaml
provider: kvm        # KVM/QEMU via Terraform (Linux x86 or ARM)
# provider: virtualbox  # VirtualBox via Vagrant (Mac/Windows/Linux)
```

### 2. Install prerequisites

```bash
./scripts/prereqs.sh
```

This installs Ansible, Terraform (KVM) or Vagrant/VirtualBox, kubectl, and all system dependencies. See [prereqs.sh](#scriptsprereqssh) for details.

> **After running prereqs.sh on KVM**, log out and back in (or run `newgrp libvirt`) so the `libvirt` and `kvm` group memberships take effect.

### 3. Bring up the cluster

```bash
./scripts/up.sh
```

This provisions the VMs, waits for SSH, then runs the full Ansible playbook. When complete, `~/.kube/config` is set to the admin kubeconfig.

```bash
kubectl get nodes
```

---

## Configuration: `config/cluster.yml`

This is the **only file you need to edit** before deploying. Every other script and playbook derives its values from here.

```yaml
cluster:
  name: k8s-kthw
  kubernetes_version: v1.34.2    # Kubernetes binary version
  etcd_version: v3.6.7           # etcd binary version
  containerd_version: v2.2.1     # containerd binary version
  cni_plugins_version: v1.9.0    # CNI plugins archive version
  cilium_version: "1.18.5"       # Cilium Helm chart / CLI version

provider: kvm      # "kvm" → Terraform + libvirt  |  "virtualbox" → Vagrant + VirtualBox

network:
  subnet: "192.168.56"           # /24 prefix; all nodes live here
  lb_last_octet: 10              # lb    → 192.168.56.10
  masters_first_octet: 11        # master-1 → .11, master-2 → .12, ...
  workers_first_octet: 21        # worker-1 → .21, worker-2 → .22, ...

  pod_cidr: "10.96.0.0/12"       # Cilium IPAM pool
  service_cidr: "10.96.0.0/12"   # kube-apiserver --service-cluster-ip-range
  service_dns_ip: "10.96.0.10"   # CoreDNS cluster IP
  service_api_ip: "10.96.0.1"    # kubernetes.default.svc cluster IP

nodes:
  loadbalancer:
    cpus: 1
    memory: 512          # MB

  masters:
    count: 3             # Must be odd for etcd quorum (1, 3, 5)
    cpus: 1
    memory: 2048         # MB

  workers:
    count: 3             # Scale freely
    cpus: 1
    memory: 2048         # MB

ssh:
  user: ubuntu
  private_key: "~/.ssh/id_rsa"
  public_key: "~/.ssh/id_rsa.pub"

arch: arm64    # "auto" (detected from uname -m) | "amd64" | "arm64"
```

**To scale the cluster**, change `masters.count` and/or `workers.count` and re-run `./scripts/up.sh`.

---

## Scripts

### `scripts/prereqs.sh`

Installs all host-side dependencies. Designed for Ubuntu 22.04 / 24.04. Must be run as a normal user with `sudo` rights (not root).

**Usage:**

```bash
./scripts/prereqs.sh              # auto-detect provider from config/cluster.yml
./scripts/prereqs.sh kvm          # force KVM prerequisites
./scripts/prereqs.sh virtualbox   # force VirtualBox + Vagrant prerequisites
```

**What it installs (all providers):**

| Package | Purpose |
|---|---|
| `python3`, `python3-yaml`, `python3-pip` | Required by `up.sh` config parsing and Ansible |
| `git`, `curl`, `wget`, `openssl`, `jq` | General tools |
| `pipx` + `ansible` | Ansible installed via pipx for isolation |
| `community.general`, `ansible.posix` | Ansible Galaxy collections used by roles |
| `kubectl` | Matching version from `cluster.yml` for local cluster access |
| SSH key (`~/.ssh/id_rsa`) | Generated if missing; injected into all VMs |

**KVM-specific (when `provider: kvm`):**

| Package | Purpose |
|---|---|
| `qemu-kvm`, `qemu-utils` | KVM hypervisor |
| `libvirt-daemon-system`, `libvirt-clients`, `libvirt-dev` | libvirt management layer |
| `bridge-utils`, `virt-manager` | Networking and VM management |
| `cpu-checker` | Validates KVM hardware acceleration via `kvm-ok` |
| `genisoimage`, `cloud-image-utils` | cloud-init ISO creation |
| `terraform` | HashiCorp Terraform (from official apt repo) |

Users are added to `libvirt` and `kvm` groups automatically.

**VirtualBox-specific (when `provider: virtualbox`):**

| Package | Purpose |
|---|---|
| `virtualbox-7.1` | Oracle VirtualBox (from official apt repo) |
| `vagrant` | HashiCorp Vagrant (from official apt repo) |
| `vagrant-hostmanager` | Vagrant plugin for `/etc/hosts` management |

> ARM64 + VirtualBox is not officially supported on Linux. Use `provider: kvm` on Linux ARM hosts.

---

### `scripts/up.sh`

The main entrypoint. Reads `config/cluster.yml`, provisions VMs via the configured provider, waits for SSH to be available on all nodes, then runs Ansible.

**Usage:**

```bash
./scripts/up.sh                              # Full run: provision VMs + deploy cluster
./scripts/up.sh --vms-only                   # Provision VMs only, skip Ansible
./scripts/up.sh --ansible-only               # Skip VM provisioning, run Ansible only
./scripts/up.sh --playbook control-plane.yml # Run a specific playbook instead of site.yml
./scripts/up.sh --destroy                    # Tear down all VMs (terraform destroy / vagrant destroy)
```

**Internal flow:**

1. Detects host architecture (`uname -m` → `amd64` / `arm64`), overridden by `arch:` in `cluster.yml`.
2. Selects the correct Ubuntu 24.04 cloud image URL for the detected architecture.
3. Parses `cluster.yml` with Python to read `provider`, network settings, and node counts.
4. **KVM path:** Generates `terraform/terraform.tfvars.json` from `cluster.yml`, then runs `terraform init -upgrade` + `terraform apply -auto-approve`.
5. **VirtualBox path:** Runs `vagrant up --provider=virtualbox` from the `vagrant/` directory.
6. Polls TCP port 22 on every node IP (with a 5-minute deadline) until SSH is available.
7. Runs `ansible-playbook` from the `ansible/` directory with the selected playbook.
8. Copies `ansible/pki/admin.kubeconfig` to `~/.kube/config` when the run completes.

---

## VM Provisioning

### KVM / Terraform

**Files:** `terraform/main.tf`, `terraform/variables.tf`, `terraform/outputs.tf`, `terraform/cloud-init/`

Uses the [`dmacvicar/libvirt`](https://registry.terraform.io/providers/dmacvicar/libvirt) Terraform provider to create KVM/QEMU virtual machines via libvirt.

**Resources created:**

| Resource | Description |
|---|---|
| `libvirt_pool.k8s` | Storage pool at `/var/lib/libvirt/images/k8s` |
| `libvirt_network.k8s` | NAT network on `192.168.56.0/24` with DNS enabled |
| `libvirt_volume.ubuntu_base` | Shared base qcow2 image (downloaded from Ubuntu cloud-images) |
| `libvirt_volume.lb` | Load-balancer disk (10 GiB, copy-on-write from base) |
| `libvirt_volume.masters[*]` | Master node disks (50 GiB each, copy-on-write) |
| `libvirt_volume.workers[*]` | Worker node disks (50 GiB each, copy-on-write) |
| `libvirt_cloudinit_disk.*` | cloud-init ISO per node (user-data + network-config) |
| `libvirt_domain.lb` | Load-balancer VM |
| `libvirt_domain.masters[*]` | Master VMs (count driven by `masters_count` variable) |
| `libvirt_domain.workers[*]` | Worker VMs (count driven by `workers_count` variable) |

**ARM64 compatibility:** On AArch64, libvirt uses the `virt` machine type instead of `pc`. Because the libvirt provider attaches cloud-init as an IDE CD-ROM (which `virt` machines lack), an XSLT transform in `main.tf` rewrites the domain XML to switch the CD-ROM bus to `scsi`.

**Terraform variables** (`terraform/variables.tf`) — normally auto-populated by `up.sh`:

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | `k8s-hardway` | Prefix for all libvirt resource names |
| `subnet` | `192.168.56` | First three octets of the /24 network |
| `lb_last_octet` | `10` | Last octet for the load-balancer |
| `masters_first_octet` | `11` | Last octet of master-1; subsequent masters increment |
| `workers_first_octet` | `21` | Last octet of worker-1; subsequent workers increment |
| `masters_count` | `2` | Number of control-plane VMs |
| `workers_count` | `2` | Number of worker VMs |
| `masters_cpus` / `masters_memory` | `2` / `2048` | Control-plane VM sizing |
| `workers_cpus` / `workers_memory` | `2` / `2048` | Worker VM sizing |
| `lb_cpus` / `lb_memory` | `1` / `512` | Load-balancer VM sizing |
| `ubuntu_image_url` | amd64 cloud image | Overridden by `up.sh` based on host arch |
| `arch` | `amd64` | Determines libvirt `machine` type (`virt` vs `pc`) |
| `libvirt_pool` | `k8s` | libvirt storage pool name |
| `ssh_public_key_path` | `~/.ssh/id_rsa.pub` | Injected into all VMs via cloud-init |

**Outputs:**

| Output | Description |
|---|---|
| `lb_ip` | IP address of the load-balancer |
| `master_ips` | Map of master name → IP |
| `worker_ips` | Map of worker name → IP |

**Cloud-init templates:**

- `cloud-init/user-data.tpl` — Sets hostname, creates `ubuntu` user with passwordless sudo, injects the SSH public key, installs base packages (`python3`, `curl`, `openssl`, `qemu-guest-agent`), writes `/etc/hosts` with all cluster node entries, disables UFW and password SSH auth.
- `cloud-init/network-config.tpl` — Configures a static IP on the virtio NIC (matches by driver name, works on both x86 and ARM regardless of interface name). Sets gateway and DNS servers (`8.8.8.8`, `1.1.1.1`).

---

### VirtualBox / Vagrant

**File:** `vagrant/Vagrantfile`

Reads `config/cluster.yml` via Ruby's YAML parser and dynamically defines VMs. Selects the correct Vagrant box based on architecture:

| Architecture | Box |
|---|---|
| x86_64 | `bento/ubuntu-24.04` |
| arm64 | `bento/ubuntu-24.04-arm64` |

Defines one VM per cluster node (lb, master-1…N, worker-1…N), each with:
- A private network interface at the configured IP
- VirtualBox provider settings (name, CPUs, memory from `cluster.yml`)
- A shell provisioner that injects the SSH public key, writes `/etc/hosts`, and installs `python3` (required by Ansible)

---

## Ansible Layer

### Dynamic Inventory: `ansible/inventory/inventory.py`

A Python script that serves as the Ansible inventory source. It reads `config/cluster.yml` and emits a JSON inventory that Ansible consumes directly — no static `hosts` file exists.

**Inventory groups emitted:**

| Group | Members |
|---|---|
| `all` | All nodes (lb + masters + workers) |
| `masters` | master-1, master-2, ... |
| `workers` | worker-1, worker-2, ... |
| `lb` | lb |
| `etcd` | Same as `masters` |
| `control_plane` | Same as `masters` |

**Per-host variables injected:**

| Variable | Description |
|---|---|
| `node_name` | e.g. `master-1` |
| `node_ip` | e.g. `192.168.56.11` |
| `node_index` | 0-based index within its group |
| `ansible_host` | Same as `node_ip` |
| `ansible_user` | From `ssh.user` in cluster.yml |
| `ansible_ssh_private_key_file` | From `ssh.private_key` in cluster.yml |

**Cluster-wide group variables (available to all roles):**

| Variable | Source |
|---|---|
| `cluster_name`, `kubernetes_version`, `etcd_version`, `containerd_version`, `cni_plugins_version`, `cilium_version` | `cluster.yml` |
| `lb_ip`, `master_ips[]`, `worker_ips[]` | Derived from network config |
| `first_master`, `first_master_ip` | First master name and IP |
| `pod_cidr`, `service_cidr`, `service_dns_ip`, `service_api_ip` | Network config |
| `k8s_cluster_name` | `network.cluster_name` |
| `pki_dir` | Absolute path to `ansible/pki/` |

**Usage:**

```bash
# List all hosts and their variables
./ansible/inventory/inventory.py --list

# Show variables for a specific host
./ansible/inventory/inventory.py --host master-1
```

---

### Playbooks

#### `playbooks/site.yml` — Full cluster deployment

The default playbook run by `up.sh`. Executes all roles in dependency order:

| Play | Target | Role(s) |
|---|---|---|
| 1 | `all` | `common` — OS baseline |
| 2 | `all` | `pki` — Generate and distribute all certificates |
| 3 | `etcd` (=masters) | `etcd` — etcd cluster |
| 4 | `lb` | `haproxy` — API server load balancer |
| 5 | `masters` (serial: 1) | `kube-apiserver`, `kube-scheduler`, `kube-controller-manager` |
| 6 | `workers` | `kubelet` — Worker node setup |
| 7 | `masters` | `kubelet` — Run kubelet on masters too (schedules system pods) |
| 8 | `masters[0]` | `cilium` — Install Cilium CNI |
| 9 | `masters[0]` | `coredns` — Deploy CoreDNS |

> Control-plane plays use `serial: 1` so each master starts and establishes etcd membership before the next one joins.

#### `playbooks/pki.yml` — PKI only

Re-generates or redistributes certificates without touching any running services. Useful after rotating certificates or when adding nodes.

```bash
cd ansible && ansible-playbook playbooks/pki.yml
```

#### `playbooks/control-plane.yml` — Control plane only

(Re)deploys etcd, HAProxy, and the Kubernetes control-plane components. Assumes PKI files already exist in `ansible/pki/`.

```bash
cd ansible && ansible-playbook playbooks/control-plane.yml
```

#### `playbooks/workers.yml` — Workers only

(Re)deploys kubelet and containerd on worker nodes. Assumes the control plane is already running.

```bash
cd ansible && ansible-playbook playbooks/workers.yml
```

---

### Roles

#### `common`

**Target:** All nodes

Sets the OS baseline required by every node:

- Updates apt cache; installs: `openssl`, `tar`, `wget`, `curl`, `vim`, `socat`, `conntrack`, `ipset`, `python3`
- Writes cluster node entries to `/etc/hosts` (lb, master-1…N, worker-1…N)
- Loads `overlay` and `br_netfilter` kernel modules (immediately + persisted via `/etc/modules-load.d/k8s.conf`)
- Applies sysctl parameters: `net.bridge.bridge-nf-call-iptables=1`, `net.bridge.bridge-nf-call-ip6tables=1`, `net.ipv4.ip_forward=1`
- Creates `/var/lib/kubernetes` and `/usr/local/bin`
- Opens firewall ports via `ufw` (masters: 2379/2380 etcd, 6443 API, 10250 kubelet, 4244/8472 Cilium, 53 DNS; workers: 10250, 8472; lb: 6443)

---

#### `pki`

**Target:** `all` (runs `delegate_to: localhost` — generates on control machine, pushes to nodes)

Generates the complete PKI from scratch using `openssl`. All steps use `creates:` for idempotency (skipped if files already exist).

**Certificate Authorities generated:**

| CA | Key size | Validity | Purpose |
|---|---|---|---|
| `etcd-ca` | 4096-bit | 10 years | Signs all etcd peer and client certs |
| `ca` (Kubernetes CA) | 2048-bit | 10 years | Signs all Kubernetes component certs |
| `front-proxy-ca` | 2048-bit | 10 years | Signs aggregation-layer client certs |

**Leaf certificates generated (signed by Kubernetes CA):**

| Certificate | CN / O | Purpose |
|---|---|---|
| `kube-apiserver` | `kube-apiserver` | API server TLS + kubelet client auth |
| `admin` | `admin / O=system:masters` | `kubectl` admin access |
| `service-account` | `service-accounts` | Service account token signing/verification |
| `kube-scheduler` | `system:kube-scheduler` | Scheduler → API server auth |
| `kube-controller-manager` | `system:kube-controller-manager` | Controller manager → API server auth |

**Per-master etcd certs (signed by etcd CA):**

- `etcd-server{1..N}.crt/key` — One cert per master, with SANs for the node IP and `localhost`. Config template: `roles/pki/templates/etcd-server.cnf.j2`.

**Kubeconfigs generated locally:**

| File | Server endpoint | Used by |
|---|---|---|
| `admin.kubeconfig` | `https://lb_ip:6443` | Local `kubectl`, admin operations |
| `kube-scheduler.kubeconfig` | `https://127.0.0.1:6443` | kube-scheduler systemd service |
| `kube-controller-manager.kubeconfig` | `https://127.0.0.1:6443` | kube-controller-manager systemd service |

**Encryption config:**

- `encryption-config.yaml` — AES-CBC encryption for etcd-stored Secrets. A random 32-byte key is generated via `/dev/urandom`.

**Distribution:**

| Files | Destination on node |
|---|---|
| `etcd-ca.{crt,key}`, `etcd-server{N}.{crt,key}` | `/etc/etcd/` on each master |
| All k8s certs, kubeconfigs, encryption-config | `/var/lib/kubernetes/` on each master |
| `ca.crt` | `/var/lib/kubernetes/ca.crt` on workers (for bootstrap) |

---

#### `etcd`

**Target:** `etcd` group (same as masters)

Deploys a TLS-secured, multi-member etcd cluster:

1. Computes the `--initial-cluster` string (e.g. `master-1=https://192.168.56.11:2380,master-2=https://...`) from `master_ips`.
2. Downloads the etcd archive from GitHub for the correct architecture.
3. Installs `etcd` and `etcdctl` to `/usr/bin/`.
4. Renders `etcd.service.j2` with node-specific flags:
   - `--name` — node hostname
   - `--cert-file` / `--key-file` / `--peer-cert-file` / `--peer-key-file` — per-node etcd TLS certs
   - `--trusted-ca-file` / `--peer-trusted-ca-file` — etcd CA
   - `--peer-client-cert-auth` + `--client-cert-auth` — mutual TLS enforced on both peer and client connections
   - `--initial-cluster` — full member list
   - `--data-dir=/var/lib/etcd`
5. Enables and starts the `etcd` systemd service.

---

#### `haproxy`

**Target:** `lb`

Configures HAProxy as a TCP load balancer in front of the Kubernetes API servers:

- Frontend: binds to `lb_ip:6443`, mode `tcp`
- Backend: round-robin across all master IPs on port 6443 with health checks (`fall 3 rise 2`)

This is the single endpoint used in `admin.kubeconfig` so clients are transparently load-balanced across all API server replicas.

---

#### `kube-apiserver`

**Target:** `masters`

1. Downloads `kube-apiserver` and `kubectl` binaries from `dl.k8s.io`.
2. Renders `kube-apiserver.service.j2` with flags including:
   - `--advertise-address` — this node's IP
   - `--apiserver-count` — total number of API server replicas
   - `--authorization-mode=Node,RBAC`
   - `--enable-admission-plugins=NodeRestriction,ServiceAccount`
   - `--enable-bootstrap-token-auth` — enables TLS bootstrap for workers
   - `--etcd-servers` — all master etcd endpoints
   - `--encryption-provider-config` — AES-CBC secret encryption at rest
   - `--service-account-issuer` / `--service-account-signing-key-file` — OIDC-style SA token signing
   - `--requestheader-*` — front-proxy aggregation layer configuration
   - `--audit-log-*` — audit logging to `/var/log/audit.log`
   - `--service-node-port-range=30000-32767`
3. Waits up to 120 seconds for port 6443 to be reachable before moving on.

---

#### `kube-scheduler`

**Target:** `masters`

Downloads `kube-scheduler` and deploys it as a systemd service. Connects to the local API server via `kube-scheduler.kubeconfig` (points to `127.0.0.1:6443`).

---

#### `kube-controller-manager`

**Target:** `masters`

Downloads `kube-controller-manager` and deploys it as a systemd service. Additionally performs one-time bootstrap RBAC setup (run once, delegated to the first master):

1. Waits for the API server on `first_master_ip:6443` to be healthy.
2. Generates a TLS bootstrap token (`openssl rand -hex`).
3. Creates a `bootstrap.kubernetes.io/token` Secret in `kube-system`.
4. Applies RBAC manifests from `roles/kube-controller-manager/files/`:

| Manifest | Purpose |
|---|---|
| `bootstrap-token.yml` | Bootstrap token Secret definition |
| `create-csrs-for-bootstrapping.yml` | ClusterRole allowing bootstrappers to create CSRs |
| `auto-approve-csrs.yml` | ClusterRoleBinding to auto-approve new node CSRs |
| `auto-approve-renewals.yml` | ClusterRoleBinding to auto-approve cert renewal CSRs |

5. Creates the `kube-apiserver-to-kubelet` ClusterRoleBinding (`system:kubelet-api-admin`).
6. Saves the bootstrap token to `ansible/pki/bootstrap-token.txt` for the kubelet role to consume.

---

#### `kubelet`

**Target:** `workers` and `masters`

Sets up the container runtime and kubelet on every node:

1. **Swap** — Disables immediately (`swapoff -a`) and comments out swap entries in `/etc/fstab`.
2. **containerd** — Downloads the archive, extracts `containerd`, `containerd-shim-runc-v2`, and `ctr` to `/usr/local/bin/`. Renders `containerd-config.toml.j2` and `containerd.service.j2`, starts containerd.
3. **runc** — Downloads the `runc` binary for the correct architecture.
4. **CNI plugins** — Downloads and extracts the official CNI plugins bundle to `/opt/cni/bin/`.
5. **kubelet** — Downloads the binary, renders `kubelet-config.yaml.j2` (cluster DNS, CA cert, etc.) and `kubelet.service.j2`.
6. **Bootstrap kubeconfig** — Reads `pki/bootstrap-token.txt` (written by the controller-manager role) and writes a `bootstrap-kubeconfig` file that allows the kubelet to request its own TLS certificate from the API server on first start.
7. Enables and starts the `kubelet` systemd service.

---

#### `cilium`

**Target:** `masters[0]` (first master only, using `kubectl`)

Installs Cilium as the cluster CNI, replacing kube-proxy:

1. Approves any pending node CSRs so workers are ready.
2. Downloads the `cilium` CLI (latest stable, architecture-detected on the remote VM).
3. Runs `cilium install` with:
   - `--version {{ cilium_version }}`
   - `--set kubeProxyReplacement=true` — full kube-proxy replacement via eBPF
   - `--set ipam.operator.clusterPoolIPv4PodCIDRList` — pod CIDR from `cluster.yml`
   - Hubble observability disabled (lightweight default; can be enabled separately)
4. Waits for Cilium to report healthy (retries 10 times, 30-second delay each).

---

#### `coredns`

**Target:** `masters[0]`

Deploys CoreDNS as the cluster DNS add-on:

1. Renders `coredns.yaml.j2` — a Deployment + Service manifest with the `service_dns_ip` from `cluster.yml` as the ClusterIP.
2. Applies the manifest via `kubectl`.
3. Waits for the `coredns` Deployment rollout to complete (5 retries, 20-second delay each).

---

## PKI Layout

All PKI artifacts are stored in `ansible/pki/` on the Ansible control machine and **must be treated as secrets** (the directory has mode `0700`).

```
ansible/pki/
├── ca.key / ca.crt                      # Kubernetes CA
├── etcd-ca.key / etcd-ca.crt            # etcd CA
├── front-proxy-ca.key / front-proxy-ca.crt
├── kube-apiserver.key / .csr / .crt
├── admin.key / .csr / .crt
├── service-account.key / .csr / .crt
├── kube-scheduler.key / .csr / .crt
├── kube-controller-manager.key / .csr / .crt
├── etcd-server{1..N}.key / .csr / .crt  # One set per master
├── etcd-master-{1..N}.cnf               # OpenSSL config per master (with SANs)
├── openssl-apiserver.cnf                 # OpenSSL config for API server SANs
├── admin.kubeconfig
├── kube-scheduler.kubeconfig
├── kube-controller-manager.kubeconfig
├── encryption-config.yaml
└── bootstrap-token.txt
```

---

## Network Layout

| Node | IP | Role |
|---|---|---|
| lb | 192.168.56.10 | HAProxy, Kubernetes API endpoint |
| master-1 | 192.168.56.11 | etcd, kube-apiserver, kube-scheduler, kube-controller-manager, kubelet |
| master-2 | 192.168.56.12 | same as master-1 |
| master-3 | 192.168.56.13 | same as master-1 |
| worker-1 | 192.168.56.21 | containerd, kubelet |
| worker-2 | 192.168.56.22 | same as worker-1 |
| worker-3 | 192.168.56.23 | same as worker-1 |

| CIDR / IP | Usage |
|---|---|
| `10.96.0.0/12` | Pod CIDR (Cilium IPAM pool) |
| `10.96.0.0/12` | Service CIDR |
| `10.96.0.1` | `kubernetes.default.svc` cluster IP |
| `10.96.0.10` | CoreDNS cluster IP |

**Port reference:**

| Port | Protocol | Used by |
|---|---|---|
| 6443 | TCP | kube-apiserver (on masters and lb) |
| 2379 | TCP | etcd client |
| 2380 | TCP | etcd peer |
| 10250 | TCP | kubelet API |
| 4244 | TCP | Cilium agent health |
| 8472 | UDP | VXLAN overlay (Cilium) |
| 53 | TCP/UDP | CoreDNS |

---

## Cluster Access

After a successful `./scripts/up.sh`, the admin kubeconfig is automatically installed:

```bash
# Already set by up.sh
kubectl get nodes
kubectl get pods -A
```

To set it manually or in another shell:

```bash
export KUBECONFIG=/path/to/ansible-samir-kthw/ansible/pki/admin.kubeconfig
kubectl get nodes
```

---

## Day-2 Operations

### Re-run only Ansible (VMs already exist)

```bash
./scripts/up.sh --ansible-only
```

### Run a specific playbook

```bash
./scripts/up.sh --playbook pki.yml
./scripts/up.sh --playbook control-plane.yml
./scripts/up.sh --playbook workers.yml
```

### Run Ansible directly (from inside the ansible/ directory)

```bash
cd ansible
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/pki.yml
ansible-playbook playbooks/workers.yml -l worker-1   # limit to one host
```

### Rotate certificates

Delete the relevant files in `ansible/pki/` and re-run the PKI playbook:

```bash
rm ansible/pki/admin.* ansible/pki/kube-apiserver.*
./scripts/up.sh --playbook pki.yml
```

### Destroy everything

```bash
./scripts/up.sh --destroy
```

### SSH into a node

```bash
ssh -i ~/.ssh/id_rsa ubuntu@192.168.56.11   # master-1
ssh -i ~/.ssh/id_rsa ubuntu@192.168.56.21   # worker-1
```

### Inspect etcd

```bash
ssh ubuntu@192.168.56.11
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/etcd-ca.crt \
  --cert=/etc/etcd/etcd-server1.crt \
  --key=/etc/etcd/etcd-server1.key \
  member list
```


**Based on** [samirahmedmustafa/kubernetes-the-hardway](https://github.com/samirahmedmustafa/kubernetes-the-hardway) — credit and original work by Samir.
