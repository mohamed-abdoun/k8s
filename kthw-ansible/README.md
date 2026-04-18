# Self-Hosted AI on Kubernetes — The Hard Way

A fully automated Kubernetes cluster built from scratch to run self-hosted AI workloads (LLMs, model servers, inference APIs). No managed cloud, no kubeadm. Every component is provisioned and wired by hand using Ansible, giving you full control over the infrastructure that runs your models.

The cluster is based on [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) and runs on KVM/QEMU VMs on your local machine (ARM or x86).

---

## What This Is For

Running AI models on infrastructure you fully own and understand:

- **LLM inference** — [Ollama](https://ollama.com), [vLLM](https://github.com/vllm-project/vllm), [llama.cpp server](https://github.com/ggerganov/llama.cpp)
- **Model serving** — [KServe](https://kserve.github.io/website/), [Triton Inference Server](https://developer.nvidia.com/triton-inference-server)
- **AI pipelines** — [Kubeflow Pipelines](https://www.kubeflow.org/docs/components/pipelines/), [Apache Airflow](https://airflow.apache.org)
- **Vector databases** — [Qdrant](https://qdrant.tech), [Weaviate](https://weaviate.io), [Milvus](https://milvus.io)
- **Observability** — Prometheus + Grafana for GPU/CPU metrics, model latency, request throughput

Because you built the cluster yourself, you can tune every layer — kernel parameters, networking (Cilium eBPF), storage classes, resource limits — for AI workload characteristics (large memory footprints, sustained CPU/GPU compute, high-bandwidth model downloads).

---

## Cluster Architecture

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

**Design decisions relevant to AI workloads:**

- `config/cluster.yml` is the **single source of truth**. Both the VM provisioner and Ansible read it — no duplicated config.
- **Cilium eBPF networking** (`kubeProxyReplacement=true`) reduces latency for high-throughput model inference traffic.
- **3-master etcd quorum** ensures the control plane survives a node failure while models are serving.
- **TLS everywhere** — all component communication is mutually authenticated. Required before exposing any AI API externally.
- Workers are sized in `cluster.yml` — scale CPUs/memory up for GPU passthrough or large model footprints.

---

## Component Versions

Configured in `config/cluster.yml`:

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
kthw-ansible/
├── config/
│   └── cluster.yml              # Single source of truth: versions, IPs, node counts
│
├── scripts/
│   ├── prereqs.sh               # Install host-side tools (Ansible, Terraform, kubectl)
│   └── up.sh                    # Main entrypoint: provision VMs + run Ansible
│
├── terraform/                   # KVM provider (libvirt)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── cloud-init/
│       ├── user-data.tpl
│       └── network-config.tpl
│
├── vagrant/
│   └── Vagrantfile              # VirtualBox provider (reads cluster.yml)
│
└── ansible/
    ├── ansible.cfg
    ├── group_vars/all.yml
    ├── inventory/inventory.py   # Dynamic inventory from cluster.yml
    ├── playbooks/
    │   ├── site.yml             # Full cluster deployment
    │   ├── pki.yml              # PKI only
    │   ├── control-plane.yml    # etcd + HAProxy + API server stack
    │   └── workers.yml          # kubelet + containerd + CNI
    └── roles/
        ├── common/              # OS baseline (kernel modules, sysctl, firewall)
        ├── pki/                 # TLS cert generation (openssl only, no cfssl/kubeadm)
        ├── etcd/                # Multi-member TLS-secured etcd
        ├── haproxy/             # TCP load balancer for API servers
        ├── kube-apiserver/
        ├── kube-scheduler/
        ├── kube-controller-manager/
        ├── kubelet/             # containerd + runc + CNI plugins + kubelet
        ├── cilium/              # eBPF CNI, kube-proxy replacement
        └── coredns/             # Cluster DNS
```

---

## Quick Start

### 1. Configure the cluster

Edit `config/cluster.yml`. At minimum, set your provider and size the workers for your AI workloads:

```yaml
provider: kvm        # "kvm" (Linux, recommended) or "virtualbox" (Mac/Windows)

nodes:
  workers:
    count: 3
    cpus: 4          # Increase for model inference
    memory: 8192     # MB — LLMs need large memory; 8–16 GB per worker recommended
```

See [Configuration Reference](#configuration-reference) for all options.

### 2. Install prerequisites

```bash
./scripts/prereqs.sh
```

Installs Ansible, Terraform (KVM) or Vagrant, kubectl, and all system dependencies.

> **KVM users:** After `prereqs.sh`, log out and back in (or run `newgrp libvirt`) for group membership to take effect.

### 3. Bring up the cluster

```bash
./scripts/up.sh
```

Provisions VMs, waits for SSH, runs the full Ansible playbook, and copies the admin kubeconfig to `~/.kube/config`.

```bash
kubectl get nodes
# NAME       STATUS   ROLES    AGE   VERSION
# master-1   Ready    <none>   ...   v1.34.2
# worker-1   Ready    <none>   ...   v1.34.2
# ...
```

### 4. Deploy your AI workload

The cluster is a standard Kubernetes cluster. Use `kubectl apply` or Helm as usual. Example — deploying Ollama for LLM inference:

```bash
# Deploy Ollama on a worker node
kubectl create namespace ai

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
      - name: ollama
        image: ollama/ollama:latest
        ports:
        - containerPort: 11434
        resources:
          requests:
            memory: "4Gi"
            cpu: "2"
          limits:
            memory: "8Gi"
            cpu: "4"
        volumeMounts:
        - name: ollama-data
          mountPath: /root/.ollama
      volumes:
      - name: ollama-data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ai
spec:
  selector:
    app: ollama
  ports:
  - port: 11434
    targetPort: 11434
  type: ClusterIP
EOF

# Pull a model
kubectl exec -n ai deploy/ollama -- ollama pull llama3.2
```

---

## Configuration Reference

`config/cluster.yml` is the only file you need to edit before deploying.

```yaml
cluster:
  name: k8s-kthw
  kubernetes_version: v1.34.2
  etcd_version: v3.6.7
  containerd_version: v2.2.1
  cni_plugins_version: v1.9.0
  cilium_version: "1.18.5"

provider: kvm      # "kvm" → Terraform + libvirt  |  "virtualbox" → Vagrant + VirtualBox

network:
  subnet: "192.168.56"           # /24 prefix; all nodes live on this network
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
    memory: 512           # MB

  masters:
    count: 3              # Must be odd for etcd quorum (1, 3, 5)
    cpus: 1
    memory: 2048          # MB

  workers:
    count: 3              # Scale freely; add more workers for more model capacity
    cpus: 4               # Raise for compute-heavy inference
    memory: 8192          # MB — match to your largest model's memory requirement

ssh:
  user: ubuntu
  private_key: "~/.ssh/id_rsa"
  public_key:  "~/.ssh/id_rsa.pub"

arch: arm64    # "auto" (detected from uname -m) | "amd64" | "arm64"
```

**Scaling workers for AI:** Change `workers.count`, `workers.cpus`, and `workers.memory`, then re-run `./scripts/up.sh`. New workers join automatically via TLS bootstrap.

---

## Scripts

### `scripts/prereqs.sh`

```bash
./scripts/prereqs.sh              # auto-detect provider from cluster.yml
./scripts/prereqs.sh kvm          # force KVM prerequisites
./scripts/prereqs.sh virtualbox   # force VirtualBox + Vagrant prerequisites
```

Installs on **all providers**: `ansible`, `kubectl`, `openssl`, `python3-yaml`, `git`, `curl`, `jq`.

**KVM-specific:** `qemu-kvm`, `libvirt-daemon-system`, `terraform`, `genisoimage`, `cloud-image-utils`. Adds you to `libvirt` and `kvm` groups.

**VirtualBox-specific:** `virtualbox-7.1`, `vagrant`, `vagrant-hostmanager`.

> ARM64 + VirtualBox is not officially supported on Linux. Use `provider: kvm` on ARM hosts.

### `scripts/up.sh`

```bash
./scripts/up.sh                              # Full run: provision VMs + deploy cluster
./scripts/up.sh --vms-only                   # Provision VMs only
./scripts/up.sh --ansible-only               # Skip VM provisioning, re-run Ansible
./scripts/up.sh --playbook control-plane.yml # Run a specific playbook
./scripts/up.sh --destroy                    # Tear down all VMs
```

**Flow:** detect arch → select Ubuntu 24.04 cloud image → generate Terraform vars or run Vagrant → wait for SSH on all nodes → run `ansible-playbook site.yml` → copy `admin.kubeconfig` to `~/.kube/config`.

---

## Network Layout

| Node | IP | Role |
|---|---|---|
| lb | 192.168.56.10 | HAProxy, Kubernetes API endpoint |
| master-1 | 192.168.56.11 | etcd, kube-apiserver, kube-scheduler, kube-controller-manager, kubelet |
| master-2 | 192.168.56.12 | same as master-1 |
| master-3 | 192.168.56.13 | same as master-1 |
| worker-1 | 192.168.56.21 | containerd, kubelet — AI workloads run here |
| worker-2 | 192.168.56.22 | same as worker-1 |
| worker-3 | 192.168.56.23 | same as worker-1 |

| CIDR / IP | Usage |
|---|---|
| `10.96.0.0/12` | Pod CIDR (Cilium IPAM pool) |
| `10.96.0.0/12` | Service CIDR |
| `10.96.0.1` | `kubernetes.default.svc` |
| `10.96.0.10` | CoreDNS |

| Port | Protocol | Component |
|---|---|---|
| 6443 | TCP | kube-apiserver (masters + lb) |
| 2379 | TCP | etcd client |
| 2380 | TCP | etcd peer |
| 10250 | TCP | kubelet API |
| 4244 | TCP | Cilium health |
| 8472 | UDP | Cilium VXLAN overlay |
| 53 | TCP/UDP | CoreDNS |

---

## Ansible Layer

### Dynamic Inventory

`ansible/inventory/inventory.py` reads `config/cluster.yml` and emits a JSON inventory. No static hosts file.

```bash
./ansible/inventory/inventory.py --list        # all hosts + vars
./ansible/inventory/inventory.py --host master-1
```

Groups: `all`, `masters`, `workers`, `lb`, `etcd`, `control_plane`.

### Playbooks

| Playbook | Purpose |
|---|---|
| `site.yml` | Full cluster (default) |
| `pki.yml` | Regenerate/redistribute certificates only |
| `control-plane.yml` | Re-deploy etcd + HAProxy + API server stack |
| `workers.yml` | Re-deploy kubelet + containerd on workers |

### Roles

| Role | What it does |
|---|---|
| `common` | Packages, kernel modules (`overlay`, `br_netfilter`), sysctl, `/etc/hosts`, firewall |
| `pki` | All TLS CAs and leaf certs via `openssl`, kubeconfigs, encryption config |
| `etcd` | Multi-member TLS-secured etcd cluster |
| `haproxy` | TCP LB: frontend `:6443` → round-robin masters `:6443` |
| `kube-apiserver` | API server binary + systemd service (RBAC, audit log, bootstrap token auth) |
| `kube-scheduler` | Scheduler binary + systemd service |
| `kube-controller-manager` | Controller manager + bootstrap RBAC (CSR auto-approval for worker join) |
| `kubelet` | containerd + runc + CNI plugins + kubelet + TLS bootstrap kubeconfig |
| `cilium` | Cilium CLI install, `kubeProxyReplacement=true`, waits for healthy |
| `coredns` | CoreDNS Deployment + Service via `kubectl apply` |

---

## PKI Layout

All PKI artifacts live in `ansible/pki/` (mode `0700`, git-ignored).

```
ansible/pki/
├── ca.key / ca.crt                       # Kubernetes CA
├── etcd-ca.key / etcd-ca.crt             # etcd CA
├── front-proxy-ca.key / front-proxy-ca.crt
├── kube-apiserver.{key,csr,crt}
├── admin.{key,csr,crt}
├── service-account.{key,csr,crt}
├── kube-scheduler.{key,csr,crt}
├── kube-controller-manager.{key,csr,crt}
├── etcd-server{1..N}.{key,csr,crt}       # One set per master
├── admin.kubeconfig
├── kube-scheduler.kubeconfig
├── kube-controller-manager.kubeconfig
├── encryption-config.yaml                # AES-CBC secret encryption at rest
└── bootstrap-token.txt
```

---

## Day-2 Operations

```bash
# Access the cluster
kubectl get nodes
kubectl get pods -A

# SSH into a node
ssh -i ~/.ssh/id_rsa ubuntu@192.168.56.21   # worker-1

# Re-run Ansible only (VMs already running)
./scripts/up.sh --ansible-only

# Run a specific playbook
./scripts/up.sh --playbook workers.yml

# Run Ansible directly
cd ansible
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/workers.yml -l worker-1   # single host

# Rotate certificates
rm ansible/pki/admin.* ansible/pki/kube-apiserver.*
./scripts/up.sh --playbook pki.yml

# Inspect etcd
ssh ubuntu@192.168.56.11 sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/etcd-ca.crt \
  --cert=/etc/etcd/etcd-server1.crt \
  --key=/etc/etcd/etcd-server1.key \
  member list

# Destroy everything
./scripts/up.sh --destroy
```

---

**Based on** [samirahmedmustafa/kubernetes-the-hardway](https://github.com/samirahmedmustafa/kubernetes-the-hardway).
