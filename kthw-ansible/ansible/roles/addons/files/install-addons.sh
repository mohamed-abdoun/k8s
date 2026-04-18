#!/usr/bin/env bash
# install-addons.sh – Install Nginx Ingress, Prometheus, and Grafana via Helm.
# Runs on a master node after the cluster is fully up.
#
# Environment variables (with defaults):
#   KUBECONFIG  – path to admin kubeconfig
#   BIN_DIR     – directory where helm binary is installed

set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/var/lib/kubernetes/admin.kubeconfig}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"

log() { echo -e "\033[1;34m[addons]\033[0m $*"; }

# ── Helm ──────────────────────────────────────────────────────────────────────
install_helm() {
  if command -v helm &>/dev/null; then
    log "Helm already installed: $(helm version --short)"
    return
  fi
  log "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | HELM_INSTALL_DIR="${BIN_DIR}" USE_SUDO=false bash
  log "Helm installed."
}

# ── Namespace helper ──────────────────────────────────────────────────────────
create_namespace() {
  kubectl --kubeconfig "${KUBECONFIG}" create namespace "$1" \
    --dry-run=client -o yaml \
    | kubectl --kubeconfig "${KUBECONFIG}" apply -f -
}

# ── Nginx Ingress Controller ──────────────────────────────────────────────────
install_nginx() {
  log "Installing Nginx Ingress Controller..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
  helm repo update ingress-nginx
  create_namespace ingress-nginx
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --kubeconfig "${KUBECONFIG}" \
    --wait --timeout 5m
  log "Nginx Ingress installed. HTTP=30080  HTTPS=30443"
}

# ── Prometheus + Grafana (kube-prometheus-stack) ──────────────────────────────
install_prometheus_grafana() {
  log "Installing Prometheus + Grafana (kube-prometheus-stack)..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
  helm repo update prometheus-community
  create_namespace monitoring
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set prometheus.service.type=NodePort \
    --set prometheus.service.nodePort=30090 \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort=30300 \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --kubeconfig "${KUBECONFIG}" \
    --wait --timeout 10m
  GRAFANA_PASSWORD=$(kubectl --kubeconfig "${KUBECONFIG}" get secret \
    -n monitoring kube-prometheus-stack-grafana \
    -o jsonpath="{.data.admin-password}" | base64 --decode)
  log "Prometheus + Grafana installed."
  log "  Prometheus : http://<node-ip>:30090"
  log "  Grafana    : http://<node-ip>:30300  (admin / ${GRAFANA_PASSWORD})"
}

# ── Main ──────────────────────────────────────────────────────────────────────
install_helm
install_nginx
install_prometheus_grafana

log ""
log "All addons installed successfully."
