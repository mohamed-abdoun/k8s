#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ai-inference-dev}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
KIND_VERSION="${KIND_VERSION:-v0.31.0}"
# Kind v0.31 currently defaults to Kubernetes v1.35.x. On this aarch64
# Docker/cgroup-v2 host that image fails before kubelet health is available,
# while v1.34.0 is multi-arch and starts cleanly.
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.34.0}"
KIND_WORKER_NODES="${KIND_WORKER_NODES:-0}"
INSTALL_INGRESS="${INSTALL_INGRESS:-true}"
INSTALL_CERT_MANAGER="${INSTALL_CERT_MANAGER:-true}"
INSTALL_METRICS_SERVER="${INSTALL_METRICS_SERVER:-true}"
INSTALL_KEDA="${INSTALL_KEDA:-true}"
INSTALL_ENVOY_GATEWAY="${INSTALL_ENVOY_GATEWAY:-true}"
INSTALL_ENVOY_AI_GATEWAY="${INSTALL_ENVOY_AI_GATEWAY:-true}"
INSTALL_KSERVE="${INSTALL_KSERVE:-true}"
INSTALL_KSERVE_LLMISVC="${INSTALL_KSERVE_LLMISVC:-false}"
INSTALL_NVIDIA_DEVICE_PLUGIN="${INSTALL_NVIDIA_DEVICE_PLUGIN:-false}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.15.1}"
KEDA_VERSION="${KEDA_VERSION:-2.19.0}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.7.2}"
ENVOY_AI_GATEWAY_VERSION="${ENVOY_AI_GATEWAY_VERSION:-v0.6.0}"
KSERVE_VERSION="${KSERVE_VERSION:-v0.17.0}"
DELETE_FAILED_CLUSTER="${DELETE_FAILED_CLUSTER:-true}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_BIN="${ROOT_DIR}/bin"
KIND_BIN="${LOCAL_BIN}/kind"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

download_kind() {
  mkdir -p "${LOCAL_BIN}"
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported architecture for kind install: ${arch}" >&2; exit 1 ;;
  esac
  url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${os}-${arch}"
  echo "Installing kind ${KIND_VERSION} to ${KIND_BIN}"
  curl -fsSL "${url}" -o "${KIND_BIN}"
  chmod +x "${KIND_BIN}"
}

kind_cmd() {
  if command -v kind >/dev/null 2>&1; then
    command kind "$@"
  else
    if [[ ! -x "${KIND_BIN}" ]]; then
      download_kind
    fi
    "${KIND_BIN}" "$@"
  fi
}

wait_rollout() {
  namespace="$1"
  selector="$2"
  kubectl -n "${namespace}" rollout status "${selector}" --timeout=180s
}

wait_nodes_ready() {
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
}

export_failed_logs() {
  log_dir="${ROOT_DIR}/tmp/kind-logs-${CLUSTER_NAME}-$(date +%Y%m%d%H%M%S)"
  mkdir -p "${log_dir}"
  echo "Kind cluster creation failed. Exporting logs to ${log_dir}" >&2
  kind_cmd export logs "${log_dir}" --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format 'kind node: {{.Names}} {{.Status}} {{.Image}}' >&2 || true
  if [[ "${DELETE_FAILED_CLUSTER}" == "true" ]]; then
    kind_cmd delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  fi
}

patch_metrics_server_for_kind() {
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null || true
}

install_keda() {
  kubectl apply --server-side -f "https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
  wait_rollout keda deployment/keda-operator
  wait_rollout keda deployment/keda-metrics-apiserver
  wait_rollout keda deployment/keda-admission
}

install_envoy_gateway() {
  kubectl apply --server-side -f "https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/install.yaml"
  wait_rollout envoy-gateway-system deployment/envoy-gateway
  kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-gateway-config
  namespace: envoy-gateway-system
data:
  envoy-gateway.yaml: |
    apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: EnvoyGateway
    provider:
      type: Kubernetes
    gateway:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
    extensionApis:
      enableBackend: true
EOF
  kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
  kubectl -n envoy-gateway-system rollout restart deployment/envoy-gateway
  wait_rollout envoy-gateway-system deployment/envoy-gateway
}

install_envoy_ai_gateway() {
  require helm
  helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
    --version "${ENVOY_AI_GATEWAY_VERSION}" \
    --namespace envoy-ai-gateway-system \
    --create-namespace
  helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
    --version "${ENVOY_AI_GATEWAY_VERSION}" \
    --namespace envoy-ai-gateway-system \
    --create-namespace
  wait_rollout envoy-ai-gateway-system deployment/ai-gateway-controller
}

install_kserve() {
  kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply --server-side --force-conflicts -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve-crds.yaml"
  kubectl apply --server-side --force-conflicts -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml"
  kubectl -n kserve patch configmap inferenceservice-config --type=merge \
    -p='{"data":{"deploy":"{\"defaultDeploymentMode\":\"RawDeployment\"}"}}'
  wait_rollout kserve deployment/kserve-controller-manager
  wait_rollout kserve deployment/kserve-localmodel-controller-manager
  wait_rollout kserve deployment/llmisvc-controller-manager
  sleep 15
  kubectl apply --server-side --force-conflicts -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve-cluster-resources.yaml"
}

require docker
require kubectl
require curl

if ! command -v go >/dev/null 2>&1; then
  echo "warning: Go is not installed. The cluster can be created, but operator builds need Go 1.25+." >&2
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is required and does not appear to be running." >&2
  exit 1
fi

if ! docker inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "${REGISTRY_NAME}" registry:2 >/dev/null
elif [[ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}")" != "true" ]]; then
  docker start "${REGISTRY_NAME}" >/dev/null
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cat > "${tmp_dir}/kind-config.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
    endpoint = ["http://${REGISTRY_NAME}:5000"]
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF

if [[ -n "${KIND_NODE_IMAGE}" ]]; then
  sed -i "/role: control-plane/a\\  image: ${KIND_NODE_IMAGE}" "${tmp_dir}/kind-config.yaml"
fi

for ((i = 0; i < KIND_WORKER_NODES; i++)); do
  {
    echo "- role: worker"
    if [[ -n "${KIND_NODE_IMAGE}" ]]; then
      echo "  image: ${KIND_NODE_IMAGE}"
    fi
  } >> "${tmp_dir}/kind-config.yaml"
done

if ! kind_cmd get clusters | grep -qx "${CLUSTER_NAME}"; then
  if ! kind_cmd create cluster --retain --wait 180s --name "${CLUSTER_NAME}" --config "${tmp_dir}/kind-config.yaml"; then
    export_failed_logs
    exit 1
  fi
else
  echo "kind cluster ${CLUSTER_NAME} already exists"
fi

wait_nodes_ready

if ! docker network inspect kind -f '{{json .Containers}}' | grep -q "\"${REGISTRY_NAME}\""; then
  docker network connect kind "${REGISTRY_NAME}" || true
fi

cat > "${tmp_dir}/local-registry-hosting.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
kubectl apply -f "${tmp_dir}/local-registry-hosting.yaml"

if [[ "${INSTALL_INGRESS}" == "true" ]]; then
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
  wait_rollout ingress-nginx deployment/ingress-nginx-controller
fi

if [[ "${INSTALL_CERT_MANAGER}" == "true" ]]; then
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  wait_rollout cert-manager deployment/cert-manager
  wait_rollout cert-manager deployment/cert-manager-cainjector
  wait_rollout cert-manager deployment/cert-manager-webhook
fi

if [[ "${INSTALL_METRICS_SERVER}" == "true" ]]; then
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  patch_metrics_server_for_kind
  wait_rollout kube-system deployment/metrics-server
fi

if [[ "${INSTALL_KEDA}" == "true" ]]; then
  install_keda
fi

if [[ "${INSTALL_ENVOY_GATEWAY}" == "true" ]]; then
  install_envoy_gateway
fi

if [[ "${INSTALL_ENVOY_AI_GATEWAY}" == "true" ]]; then
  install_envoy_ai_gateway
fi

if [[ "${INSTALL_KSERVE}" == "true" ]]; then
  if [[ "${INSTALL_KSERVE_LLMISVC}" == "true" ]]; then
    curl -fsSL "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/llmisvc-dependency-install.sh" -o "${tmp_dir}/llmisvc-dependency-install.sh"
    bash "${tmp_dir}/llmisvc-dependency-install.sh"
  fi
  install_kserve
fi

if [[ "${INSTALL_NVIDIA_DEVICE_PLUGIN}" == "true" ]]; then
  kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml
  kubectl -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset --timeout=180s
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo
echo "Kind development cluster is ready."
echo "Local registry: localhost:${REGISTRY_PORT}"
echo "Node image: ${KIND_NODE_IMAGE:-kind default}"
echo "Worker nodes: ${KIND_WORKER_NODES}"
echo "Installed control planes:"
echo "  ingress-nginx=${INSTALL_INGRESS}"
echo "  cert-manager=${INSTALL_CERT_MANAGER}"
echo "  metrics-server=${INSTALL_METRICS_SERVER}"
echo "  keda=${INSTALL_KEDA}"
echo "  envoy-gateway=${INSTALL_ENVOY_GATEWAY}"
echo "  envoy-ai-gateway=${INSTALL_ENVOY_AI_GATEWAY}"
echo "  kserve=${INSTALL_KSERVE}"
echo "Build and deploy operator:"
echo "  docker build -t localhost:${REGISTRY_PORT}/ai-inference-operator:dev ."
echo "  docker push localhost:${REGISTRY_PORT}/ai-inference-operator:dev"
echo "  kubectl apply -k config/default"
