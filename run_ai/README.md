# Run:ai Installation on KTHW Cluster

Installation guide for [Run:ai](https://www.run.ai) on the self-hosted Kubernetes cluster built in `../kthw-ansible/`.

Run:ai is a GPU workload scheduler and orchestration platform for AI/ML. It adds GPU sharing, quotas, fair scheduling, and a workload management UI on top of Kubernetes.

---

## Access Strategy

This guide follows a two-phase access model:

| Phase | Access method | When to use |
|---|---|---|
| **Phase 1** | `kubectl port-forward` from the host | Initial install and smoke-testing |
| **Phase 2** | MetalLB + Ingress + DNS on host network | After verifying the installation works |

Complete Phase 1 first. Only move to Phase 2 once Run:ai is confirmed healthy.

---

## GPU Mode

This guide supports both real and simulated GPUs. Choose one mode and follow only that section.

| Mode | Section | Use when |
|---|---|---|
| **Real GPU** | [1A — NVIDIA GPU Operator](#1a--real-nvidia-gpu-operator) | Worker VMs have GPU passthrough |
| **Fake GPU** | [1B — Fake GPU Operator](#1b--fake-gpu-operator) | No physical GPU on the host |

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [1A. Real NVIDIA GPU Operator](#1a--real-nvidia-gpu-operator)
- [1B. Fake GPU Operator](#1b--fake-gpu-operator)
- [2. SSL Certificates](#2-ssl-certificates)
- [3. Ingress Controller](#3-ingress-controller)
- [4. Install Run:ai](#4-install-runai)
  - [Option A — SaaS, no license needed](#option-a--saas-hosted-control-plane)
  - [Option B — Self-Hosted, requires license](#option-b--self-hosted)
- [5. Phase 1 — Access from Host via Port-Forward](#5-phase-1--access-from-host-via-port-forward)
- [6. Phase 2 — Host Network Access via MetalLB](#6-phase-2--host-network-access-via-metallb)
- [7. Verify GPU Resources](#7-verify-gpu-resources)
- [8. Configure Projects and Quotas](#8-configure-projects-and-quotas)
- [9. Submit Your First Job](#9-submit-your-first-job)
- [10. Run:ai CLI](#10-runai-cli)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Check |
|---|---|
| KTHW cluster up and all nodes `Ready` | `kubectl get nodes` |
| Kubernetes v1.26+ | Cluster is v1.34.2 ✓ |
| Helm 3 | `helm version --short` |
| `openssl` on the host | `openssl version` |
| Internet access from nodes | For image pulls |
| Run:ai account | [app.run.ai](https://app.run.ai) (SaaS) or self-hosted license |

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -Ev 'Running|Completed'
helm version --short
openssl version
```

---

## 1A — Real NVIDIA GPU Operator

> **Skip this section if your host has no GPU.** Go to [1B — Fake GPU Operator](#1b--fake-gpu-operator) instead.

The NVIDIA GPU Operator deploys NVIDIA drivers, the container toolkit, and the device plugin as DaemonSets on GPU-bearing worker nodes.

### 1A.1 — Configure containerd on GPU workers

SSH into each worker that has a GPU:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@192.168.56.21   # repeat for each GPU worker
```

```bash
# Install NVIDIA container toolkit
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -sL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# Wire the NVIDIA runtime into containerd
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

### 1A.2 — Install cert-manager (required by GPU Operator)

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
kubectl wait --for=condition=available --timeout=120s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=120s deployment/cert-manager-webhook -n cert-manager
```

### 1A.3 — Install the NVIDIA GPU Operator

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=true \
  --set toolkit.enabled=true \
  --set devicePlugin.enabled=true \
  --set migManager.enabled=false \
  --wait --timeout=10m
```

### 1A.4 — Verify

```bash
kubectl get pods -n gpu-operator
# All pods Running or Completed

kubectl get nodes -o custom-columns=\
"NAME:.metadata.name,GPUs:.status.allocatable.nvidia\.com/gpu"
# GPU worker nodes should show a non-zero count
```

---

## 1B — Fake GPU Operator

> **Skip this section if you have real GPUs.** Go to [1A — Real NVIDIA GPU Operator](#1a--real-nvidia-gpu-operator) instead.

The [fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator) is maintained by Run:ai. It reads node labels and advertises `nvidia.com/gpu` extended resources identically to the real operator — no GPU hardware required.

### 1B.1 — Label worker nodes to simulate GPUs

```bash
# Simulate 1 GPU per worker — adjust gpu.count and gpu.memory as needed
for i in 1 2 3; do
  kubectl label node worker-$i \
    nvidia.com/gpu.count=1 \
    nvidia.com/gpu.memory=40960 \
    nvidia.com/gpu.product=NVIDIA-A100-SXM4-40GB-FAKE \
    --overwrite
done

# Verify labels were applied
kubectl get nodes -l nvidia.com/gpu.count --show-labels
```

You can simulate any GPU product name and memory size. Run:ai uses these to populate the GPU inventory in the UI.

### 1B.2 — Install the fake-gpu-operator

```bash
helm repo add fake-gpu-operator https://run-ai.github.io/fake-gpu-operator
helm repo update

helm install gpu-operator fake-gpu-operator/fake-gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --wait
```

### 1B.3 — Verify

```bash
kubectl get pods -n gpu-operator
# All pods Running

kubectl get nodes -o custom-columns=\
"NAME:.metadata.name,GPUs:.status.allocatable.nvidia\.com/gpu"
# NAME       GPUs
# worker-1   1
# worker-2   1
# worker-3   1
```

---

## 2. SSL Certificates

Run:ai's backend and ingress require TLS. These steps generate a local CA and a wildcard certificate for the `runai.local` domain. The same certificate is reused for the ingress in Phase 2.

All files are generated in `./pki/` inside this directory. **Do not commit them.**

```bash
mkdir -p pki
```

### 2.1 — Generate a local CA

```bash
# CA private key
openssl genrsa -out pki/runai-ca.key 4096

# CA certificate (10-year validity)
openssl req -new -x509 -days 3650 \
  -key pki/runai-ca.key \
  -out pki/runai-ca.crt \
  -subj "/CN=RunAI Local CA/O=Home Cluster"
```

### 2.2 — Generate a wildcard certificate for `*.runai.local`

```bash
# Server key
openssl genrsa -out pki/runai-tls.key 2048

# CSR with SAN extension
openssl req -new \
  -key pki/runai-tls.key \
  -out pki/runai-tls.csr \
  -subj "/CN=*.runai.local/O=Home Cluster" \
  -addext "subjectAltName=DNS:*.runai.local,DNS:runai.local"

# Sign with the local CA
openssl x509 -req -days 825 \
  -in pki/runai-tls.csr \
  -CA pki/runai-ca.crt \
  -CAkey pki/runai-ca.key \
  -CAcreateserial \
  -out pki/runai-tls.crt \
  -extfile <(printf "subjectAltName=DNS:*.runai.local,DNS:runai.local")

# Verify
openssl verify -CAfile pki/runai-ca.crt pki/runai-tls.crt
openssl x509 -in pki/runai-tls.crt -noout -text | grep -A2 "Subject Alternative"
```

### 2.3 — Create the TLS secret in Kubernetes

```bash
kubectl create namespace runai-backend 2>/dev/null || true
kubectl create namespace runai 2>/dev/null || true

# TLS secret used by Ingress
kubectl create secret tls runai-tls \
  --cert=pki/runai-tls.crt \
  --key=pki/runai-tls.key \
  -n runai-backend

# CA bundle — Run:ai backend needs to trust it internally
kubectl create configmap runai-ca \
  --from-file=ca.crt=pki/runai-ca.crt \
  -n runai-backend
```

### 2.4 — Trust the CA on the host machine

So your browser doesn't show certificate warnings when accessing the Run:ai UI:

```bash
# Ubuntu / Debian host
sudo cp pki/runai-ca.crt /usr/local/share/ca-certificates/runai-local-ca.crt
sudo update-ca-certificates

# Then restart your browser
```

---

## 3. Ingress Controller

Run:ai's UI and API are exposed through an Ingress. Install NGINX Ingress Controller before installing Run:ai.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait --timeout=5m

# Check what IP/port was assigned
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

> In Phase 1 the LoadBalancer service will stay in `<pending>` because there is no cloud load balancer. That is expected — port-forwarding bypasses it. MetalLB in Phase 2 resolves this.

---

## 4. Install Run:ai

| Option | Control plane | License needed | Best for |
|---|---|---|---|
| **A — SaaS** | Hosted by Run:ai at `app.run.ai` | No — free account | Learning, practice, evaluation |
| **B — Self-Hosted** | Runs inside your cluster | Yes — paid license | Production on-prem deployments |

> **For learning without a license, use Option A.** The SaaS control plane exposes the full Run:ai UI — project management, quota system, scheduler dashboards, job submission — everything you need to understand how Run:ai works. The concepts and architecture are identical to self-hosted; only who operates the backend differs.

---

### Option A — SaaS (Hosted Control Plane)

Run:ai hosts the control plane. You install only the cluster agent locally. The agent connects out to `app.run.ai` over HTTPS — no inbound firewall rules needed.

**What you get with a free account:**
- Full Run:ai UI (projects, departments, users, quotas, dashboards)
- Job scheduler and GPU sharing policies
- Cluster and node GPU inventory
- Workload submission and monitoring

#### 4A.1 — Create a free account and register your cluster

1. Sign up at [app.run.ai](https://app.run.ai)
2. Go to **Clusters** → **New Cluster**
3. Kubernetes distribution: `Other`
4. Copy the generated `helm install` command — it contains a unique client secret for your cluster

#### 4A.2 — Install the cluster agent

The UI gives you the exact command. The structure is:

```bash
helm repo add runai https://runai.jfrog.io/artifactory/api/helm/runai-helm
helm repo update

helm install runai-cluster runai/runai-cluster \
  --namespace runai \
  --create-namespace \
  --set controlPlane.url=<your-tenant>.run.ai \
  --set controlPlane.clientSecret=<secret-from-ui> \
  --set global.clusterDomain=<your-cluster-name> \
  --wait --timeout=10m
```

> Use the exact command from the UI — do not construct it manually. The client secret is generated per cluster.

#### 4A.3 — Verify

```bash
kubectl get pods -n runai
# All pods Running

# Check cluster status in the UI:
# app.run.ai → Clusters → your cluster → Status: Connected
```

---

### Option B — Self-Hosted

> **Requires a paid Run:ai license.** The Helm charts for the backend are not publicly accessible — `helm repo add` will fail without credentials provided by Run:ai.
>
> If you want to understand the self-hosted control plane architecture while waiting for a license, the SaaS option (A) is functionally identical from the cluster agent's perspective. The `runai-cluster` agent does not know or care whether the control plane is SaaS or self-hosted.

#### 4B.1 — Add the Run:ai Helm repo (requires license credentials)

```bash
helm repo add runai https://runai.jfrog.io/artifactory/api/helm/runai-helm \
  --username <runai-provided-username> \
  --password <runai-provided-token>
helm repo update
```

#### 4B.2 — Install the Run:ai backend (control plane)

```bash
helm install runai-backend runai/runai-backend \
  --namespace runai-backend \
  --create-namespace \
  --set global.domain=runai.local \
  --set global.tls.secretName=runai-tls \
  --set postgresql.auth.password=<choose-a-strong-password> \
  --wait --timeout=15m
```

#### 4B.3 — Install the cluster agent

```bash
helm install runai-cluster runai/runai-cluster \
  --namespace runai \
  --create-namespace \
  --set controlPlane.url=https://runai.local \
  --set global.clusterDomain=home-cluster \
  --set ingress.tlsSecretName=runai-tls \
  --wait --timeout=10m
```

---

## 5. Phase 1 — Access from Host via Port-Forward

Use this immediately after installation to verify Run:ai is working before setting up MetalLB and DNS.

### 5.1 — Port-forward the Run:ai backend UI

```bash
# SaaS: the UI is at app.run.ai — nothing to forward
# Self-hosted only:
kubectl port-forward svc/runai-backend 8443:443 -n runai-backend &
```

Access the UI at `https://localhost:8443`.

### 5.2 — Port-forward the Ingress controller

If Run:ai routes through the Ingress controller:

```bash
kubectl port-forward svc/ingress-nginx-controller 8443:443 -n ingress-nginx &
```

Then add a temporary entry to `/etc/hosts` on the host:

```bash
echo "127.0.0.1  runai.local app.runai.local" | sudo tee -a /etc/hosts
```

Access at `https://app.runai.local:8443`.

### 5.3 — Smoke test

```bash
# All Run:ai pods healthy
kubectl get pods -n runai
kubectl get pods -n runai-backend   # self-hosted only

# GPU resources visible
kubectl get nodes -o custom-columns=\
"NAME:.metadata.name,GPUs:.status.allocatable.nvidia\.com/gpu"

# Run:ai node pools registered
kubectl get runainodepool -n runai 2>/dev/null || echo "CRD not yet registered — wait a moment"
```

Once satisfied, proceed to Phase 2.

---

## 6. Phase 2 — Host Network Access via MetalLB

MetalLB assigns real IPs from your host network to Kubernetes `LoadBalancer` services, making them directly reachable from the host (and any machine on `192.168.56.0/24`) without port-forwarding.

### 6.1 — Install MetalLB

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --wait --timeout=5m

# Wait for the webhook to be ready before applying config
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

### 6.2 — Configure the IP address pool

Allocate a range from the cluster's subnet (`192.168.56.0/24`) that is **not** used by any VM. The cluster VMs use `.10`–`.23`, so `.100`–`.120` is safe:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: runai-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.56.100-192.168.56.120
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: runai-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - runai-pool
EOF
```

### 6.3 — Confirm the Ingress controller gets an IP

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# EXTERNAL-IP should now be 192.168.56.100 (or the first available in the pool)
```

Note the assigned IP — you'll use it in the next step.

### 6.4 — Add DNS entries on the host

Replace `192.168.56.100` with whatever IP MetalLB assigned:

```bash
# Remove the temporary port-forward entries added in Phase 1
sudo sed -i '/runai.local/d' /etc/hosts

# Add the real LoadBalancer IP
echo "192.168.56.100  runai.local app.runai.local" | sudo tee -a /etc/hosts
```

> For a more permanent setup, add these entries to your router's DNS or run a local `dnsmasq` instance on the host.

### 6.5 — Kill the port-forward processes

```bash
pkill -f "kubectl port-forward"
```

### 6.6 — Verify direct access

```bash
# HTTPS should resolve directly — no port number needed
curl -k https://runai.local/healthz
# or open https://app.runai.local in your browser

# The TLS cert should be valid (CA was trusted in step 2.4)
curl --cacert pki/runai-ca.crt https://runai.local/healthz
```

---

## 7. Verify GPU Resources

```bash
# Node GPU allocatable capacity
kubectl get nodes -o custom-columns=\
"NAME:.metadata.name,\
GPU:.status.allocatable.nvidia\.com/gpu,\
CPU:.status.allocatable.cpu,\
MEM:.status.allocatable.memory"

# Run:ai node pools
kubectl get runainodepool -n runai

# Run:ai CLI
runai cluster info
```

---

## 8. Configure Projects and Quotas

```bash
# Create a project with a GPU quota
runai project create ai-team --gpu-quota 2

# List projects
runai project list

# Set active project
runai config project ai-team
```

In the Run:ai UI:
1. **Departments** → create a department (e.g., `engineering`)
2. **Projects** → assign to department, set GPU quota
3. **Users** → create users, assign to projects

---

## 9. Submit Your First Job

### Interactive shell

```bash
runai submit \
  --name test-gpu \
  --project ai-team \
  --image nvidia/cuda:12.3.0-base-ubuntu22.04 \
  --gpu 1 \
  --interactive \
  -- bash
```

### Training job

```bash
runai submit \
  --name llm-finetune \
  --project ai-team \
  --image pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime \
  --gpu 1 \
  --cpu 4 \
  --memory 8G \
  -- python /workspace/train.py --epochs 10
```

### Inference server

```bash
runai submit \
  --name ollama-server \
  --project ai-team \
  --image ollama/ollama:latest \
  --gpu 1 \
  --memory 8G \
  --service-type ClusterIP \
  --port 11434 \
  -- ollama serve
```

### Status

```bash
runai list jobs
runai describe job <name>
runai logs <name> --follow
```

---

## 10. Run:ai CLI

```bash
# Download (check https://docs.run.ai for the latest version)
wget -O runai https://github.com/run-ai/runai-cli/releases/latest/download/runai-linux-amd64
chmod +x runai && sudo mv runai /usr/local/bin/

runai version

# SaaS login
runai login

# Self-hosted
runai config set controlplane-url https://runai.local
```

**Reference:**

```bash
runai project list
runai config project <project>
runai submit ...
runai list jobs [-A]
runai describe job <name>
runai logs <name> --follow
runai exec -it <name> -- bash
runai delete job <name>
runai top node
runai top job
```

---

## Troubleshooting

### Run:ai pods not starting

```bash
kubectl get pods -n runai
kubectl describe pod <pod> -n runai
kubectl logs <pod> -n runai
```

### GPU not visible to Kubernetes

**Real GPU:**
```bash
# Check GPU Operator DaemonSets
kubectl get ds -n gpu-operator
kubectl get pods -n gpu-operator

# Confirm containerd uses the NVIDIA runtime on the worker
ssh ubuntu@192.168.56.21 "sudo cat /etc/containerd/config.toml | grep -A5 nvidia"

# Re-configure if missing
ssh ubuntu@192.168.56.21 "sudo nvidia-ctk runtime configure --runtime=containerd && sudo systemctl restart containerd"
```

**Fake GPU:**
```bash
# Check node labels
kubectl describe node worker-1 | grep -i gpu

# Re-apply labels if missing
for i in 1 2 3; do
  kubectl label node worker-$i \
    nvidia.com/gpu.count=1 \
    nvidia.com/gpu.memory=40960 \
    nvidia.com/gpu.product=NVIDIA-A100-SXM4-40GB-FAKE \
    --overwrite
done

# Check fake-gpu-operator pods
kubectl get pods -n gpu-operator
kubectl logs -n gpu-operator -l app=fake-gpu-operator

# Confirm extended resource appeared
kubectl get node worker-1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
```

### MetalLB not assigning IPs

```bash
# Check MetalLB controller and speaker
kubectl get pods -n metallb-system
kubectl logs -n metallb-system deploy/metallb-controller

# Verify the IPAddressPool was created
kubectl get ipaddresspool -n metallb-system

# Check L2Advertisement
kubectl get l2advertisement -n metallb-system
```

### TLS certificate errors in the browser

```bash
# Check the cert SANs
openssl x509 -in pki/runai-tls.crt -noout -text | grep -A3 "Subject Alternative"

# Verify the CA was added to the host trust store
update-ca-certificates --verbose 2>&1 | grep runai

# Check the TLS secret in the cluster
kubectl get secret runai-tls -n runai-backend -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -text | grep -A3 "Subject Alternative"
```

### Ingress not routing to Run:ai

```bash
kubectl get ingress -A
kubectl describe ingress -n runai-backend

# Confirm Ingress controller picked up the rules
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=30
```

### Jobs stuck in Pending — "Insufficient nvidia.com/gpu"

```bash
# Total GPU capacity across the cluster
kubectl get nodes -o custom-columns=\
"NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu"

# Run:ai scheduler logs
kubectl logs -n runai deploy/runai-scheduler --tail=50

# Project quota
runai project list
```

---

## References

- [Run:ai Documentation](https://docs.run.ai)
- [Run:ai Cluster Installation](https://docs.run.ai/latest/admin/runai-setup/cluster-setup/cluster-install/)
- [fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator)
- [MetalLB](https://metallb.universe.tf)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx)
- Kubernetes cluster: `../kthw-ansible/`
