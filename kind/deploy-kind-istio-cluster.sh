#!/usr/bin/env bash

set -euo pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

########################################
# Variables
########################################
CLUSTER_NAME="istio"
CLUSTER_CONFIG="istio-cluster.yaml"
NAMESPACE_MONITORING="monitoring"
NAMESPACE_ISTIO="istio-system"
METALLB_NAMESPACE="metallb-system"

########################################
# Functions
########################################

check_command() {
  if ! command -v "$1" &> /dev/null; then
    echo -e "${RED}ERROR: '$1' command not found. Please install it before running this script.${NC}"
    exit 1
  fi
}

########################################
# Pre-flight Checks
########################################
echo -e "${CYAN}Checking required commands...${NC}"
check_command kind
check_command kubectl
check_command helm
check_command jq
check_command docker
echo -e "${GREEN}All required commands are available.${NC}"

########################################
# Cluster Setup
########################################
echo -e "${CYAN}Creating Kind cluster '${CLUSTER_NAME}'...${NC}"
kind create cluster --config="$CLUSTER_CONFIG"
echo -e "${GREEN}Kind cluster '${CLUSTER_NAME}' created successfully.${NC}"

kubectl cluster-info
echo -e "${GREEN}Cluster is up and accessible.${NC}"

########################################
# Install Cilium CNI
########################################
echo -e "${CYAN}Installing Cilium CNI...${NC}"
cilium install
cilium status --wait
cilium hubble enable --ui
cilium status
#cilium connectivity test --request-timeout 30s --connect-timeout 10s
#helm repo add cilium https://helm.cilium.io/ && echo -e "${GREEN}Cilium repo added.${NC}"
#helm repo update && echo -e "${GREEN}Helm repos updated.${NC}"
#helm upgrade --install cilium cilium/cilium --version 1.14.6 \
#  --namespace kube-system \
#  --set kubeProxyReplacement=partial \
#  --set ipam.mode=kubernetes \
#  --set tunnel=disabled \
#  --set autoDirectNodeRoutes=true \
#  --set bpf.masquerade=false \
#  --set identityAllocationMode=crd \
#  --set policyEnforcement=default \
#  --set hubble.enabled=true \
#  --set hubble.relay.enabled=true \
#  --set hubble.ui.enabled=true

echo -e "${YELLOW}Waiting for Cilium to be ready...${NC}"
kubectl rollout status -n kube-system daemonset/cilium
echo -e "${GREEN}Cilium CNI installation completed successfully.${NC}"


########################################
# Install Calico CNI
########################################
#echo -e "${CYAN}Installing Calico CNI...${NC}"
#kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
#echo -e "${YELLOW}Waiting for Calico to be ready...${NC}"
#kubectl rollout status -n kube-system daemonset/calico-node
#echo -e "${GREEN}Calico CNI installation completed successfully.${NC}"



########################################
# Install MetalLB
########################################
echo -e "${CYAN}Installing MetalLB...${NC}"
helm repo add metallb https://metallb.github.io/metallb && echo -e "${GREEN}MetalLB repo added.${NC}"
helm repo update && echo -e "${GREEN}Helm repos updated.${NC}"

helm install metallb metallb/metallb -n "$METALLB_NAMESPACE" --create-namespace
echo -e "${YELLOW}Waiting for MetalLB controller to be ready...${NC}"
kubectl rollout status -n "$METALLB_NAMESPACE" deployment/metallb-controller
echo -e "${GREEN}MetalLB installed successfully.${NC}"

echo -e "${CYAN}Configuring MetalLB IPAddressPool...${NC}"
SUBNET_JSON=$(docker network inspect kind | jq '.[0].IPAM.Config')
SUBNET=$(echo "$SUBNET_JSON" | jq -r '.[0].Subnet')
echo -e "${GREEN}Kind cluster network: $SUBNET${NC}"
echo -e "${GREEN}Using IP range 172.18.1.100-172.18.1.200 for MetalLB...${NC}"

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.18.1.100-172.18.1.200
EOF

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF
echo -e "${GREEN}MetalLB IPAddressPool and L2Advertisement configured.${NC}"

########################################
# Install NGINX Ingress Controller
########################################
echo -e "${CYAN}Installing NGINX Ingress Controller...${NC}"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
echo -e "${YELLOW}Waiting for ingress controller to be ready...${NC}"
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
echo -e "${GREEN}NGINX Ingress Controller installed successfully.${NC}"

########################################
# Deploy Test Application and Ingress
########################################
echo -e "${CYAN}Deploying test application 'my-app'...${NC}"
kubectl create deployment my-app --image=nginx:latest --port=80
kubectl expose deployment my-app --type=LoadBalancer --port=80
echo -e "${GREEN}my-app deployed and exposed as LoadBalancer service.${NC}"

echo -e "${CYAN}Creating Ingress resource for my-app...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: my-app.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app
            port:
              number: 80
EOF
echo -e "${GREEN}Ingress resource for my-app created.${NC}"

########################################
# Install Prometheus
########################################
echo -e "${CYAN}Installing Prometheus...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && echo -e "${GREEN}Prometheus repo added.${NC}"
helm repo update && echo -e "${GREEN}Helm repos updated.${NC}"
helm install --create-namespace --namespace "$NAMESPACE_MONITORING" prometheus prometheus-community/prometheus
echo -e "${YELLOW}Waiting for Prometheus pods to be ready...${NC}"
# Replace statefulset with deployment
kubectl rollout status -n "$NAMESPACE_MONITORING" deployment/prometheus-server
echo -e "${GREEN}Prometheus installed successfully.${NC}"


########################################
# Install Grafana
########################################
echo -e "${CYAN}Installing Grafana...${NC}"
helm repo add grafana https://grafana.github.io/helm-charts && echo -e "${GREEN}Grafana repo added.${NC}"
helm repo update && echo -e "${GREEN}Helm repos updated.${NC}"
helm install --namespace "$NAMESPACE_MONITORING" grafna grafana/grafana
echo -e "${YELLOW}Waiting for Grafana pod to be ready...${NC}"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n "$NAMESPACE_MONITORING" --timeout=180s
echo -e "${GREEN}Grafana installed successfully.${NC}"

GRAFANA_PW=$(kubectl get secret --namespace "$NAMESPACE_MONITORING" grafna-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
echo -e "${GREEN}Grafana admin password: $GRAFANA_PW${NC}"

POD_NAME=$(kubectl get pods --namespace "$NAMESPACE_MONITORING" -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=grafna" -o jsonpath="{.items[0].metadata.name}")
echo -e "${GREEN}Grafana Pod: $POD_NAME${NC}"
echo -e "${YELLOW}You can port-forward with:${NC}"
echo -e "${YELLOW}  kubectl --namespace monitoring port-forward $POD_NAME 3000${NC}"

########################################
# Install Istio
########################################
echo -e "${CYAN}Installing Istio...${NC}"
helm repo add istio https://istio-release.storage.googleapis.com/charts && echo -e "${GREEN}Istio repo added.${NC}"
helm repo update && echo -e "${GREEN}Helm repos updated.${NC}"

kubectl create namespace "$NAMESPACE_ISTIO" || true

helm install istio-base istio/base -n "$NAMESPACE_ISTIO" --version 1.21.0
echo -e "${YELLOW}Waiting a moment for istio-base CRDs...${NC}"
sleep 10

helm install istiod istio/istiod -n "$NAMESPACE_ISTIO" \
  --version 1.21.0 \
  --set global.proxy.autoInject=enabled \
  --set global.proxy.privileged=true \
  --set meshConfig.accessLogFile="/dev/stdout" \
  --set persistence.enabled=true \
  --set persistence.storageClass=local-path \
  --set persistence.size=8Gi

echo -e "${YELLOW}Waiting for istiod to be ready...${NC}"
kubectl rollout status -n "$NAMESPACE_ISTIO" deployment/istiod

helm install istio-ingressgateway istio/gateway -n "$NAMESPACE_ISTIO" --version 1.21.0
echo -e "${YELLOW}Waiting for istio-ingressgateway to be ready...${NC}"
kubectl rollout status -n "$NAMESPACE_ISTIO" deployment/istio-ingressgateway

echo -e "${GREEN}Istio installed successfully.${NC}"

########################################
# Done
########################################
echo -e "${GREEN}All steps completed successfully!${NC}"
echo -e "${CYAN}You can now access your my-app via Ingress on host: http://my-app.local ${NC}"
echo -e "${CYAN}(after adding an entry in /etc/hosts mapping my-app.local to your host machine's IP).${NC}"
