# AI Inference Operator

Kubernetes operator for creating AI inference workloads from an
`AIInferenceService` custom resource.

The active controller reconciles each `AIInferenceService` into platform
resources:

- KServe `InferenceService` in RawDeployment mode.
- Predictor `Deployment` and `Service` managed by KServe.
- Optional KEDA autoscaling when `spec.autoscaling` is set.
- Optional Gateway API `Gateway`.
- Optional Envoy AI Gateway `Backend`, `AIServiceBackend`, and `AIGatewayRoute`.
- Status with a `Ready` condition and resolved endpoint.

## Prerequisites

Install these tools on the machine where you run the setup:

- Docker, with the daemon running.
- `kubectl`.
- `curl`.
- `helm`, required when installing Envoy AI Gateway.
- Go 1.25 or newer, required for local `go test`, `go build`, and `go run`.

The Docker image build also works without a host Go install because the
`Dockerfile` uses `golang:1.25` as the builder image.

## Create a Local Cluster

From the repository root:

```bash
hack/kind-up.sh
```

The script creates or reuses:

- Kind cluster: `ai-inference-dev`.
- Local registry: `localhost:5001`.
- Default node image: `kindest/node:v1.34.0`.
- Platform dependencies: ingress-nginx, cert-manager, metrics-server, KEDA,
  Envoy Gateway, Envoy AI Gateway, and KServe.
- Envoy Gateway configuration with `extensionApis.enableBackend: true`, which
  is required because Envoy AI Gateway routes reference Envoy Gateway `Backend`
  resources.

Useful setup overrides:

```bash
# Create one worker node.
KIND_WORKER_NODES=1 hack/kind-up.sh

# Skip optional ingress/cert-manager/metrics-server installs.
INSTALL_INGRESS=false INSTALL_CERT_MANAGER=false INSTALL_METRICS_SERVER=false hack/kind-up.sh

# Install the NVIDIA device plugin for GPU nodes.
INSTALL_NVIDIA_DEVICE_PLUGIN=true hack/kind-up.sh
```

After the script finishes, confirm the cluster and platform pods:

```bash
kubectl config current-context
kubectl get nodes
kubectl get pods -A
kubectl get gatewayclass envoy-gateway
```

## Build and Deploy the Operator

Build the controller image and push it to the Kind-local registry:

```bash
docker build -t localhost:5001/ai-inference-operator:dev .
docker push localhost:5001/ai-inference-operator:dev
```

Install the CRD, RBAC, namespace, and controller Deployment:

```bash
kubectl apply -k config/default
kubectl rollout status deployment/ai-inference-operator-controller-manager \
  -n ai-inference-operator-system --timeout=180s
```

The default kustomize image replacement is already configured in
`config/manager/kustomization.yaml`:

```yaml
images:
- name: controller
  newName: localhost:5001/ai-inference-operator
  newTag: dev
```

If you rebuild the same `:dev` tag and need the running pod to pull it again:

```bash
kubectl rollout restart deployment/ai-inference-operator-controller-manager \
  -n ai-inference-operator-system
kubectl rollout status deployment/ai-inference-operator-controller-manager \
  -n ai-inference-operator-system --timeout=180s
```

## Run Checks

When Go is installed:

```bash
go test ./...
```

Cluster-level validation:

```bash
kubectl get crd aiinferenceservices.inference.ai \
  inferenceservices.serving.kserve.io \
  scaledobjects.keda.sh \
  gateways.gateway.networking.k8s.io \
  backends.gateway.envoyproxy.io \
  aiservicebackends.aigateway.envoyproxy.io \
  aigatewayroutes.aigateway.envoyproxy.io
```

## Smoke Test

Apply the lightweight echo sample:

```bash
kubectl apply -f config/samples/inference_v1_inferenceservice_autoscaled.yaml
kubectl wait aiinferenceservice/autoscaled-echo -n default \
  --for=condition=Ready --timeout=300s
```

Check the resources created by the operator and platform controllers:

```bash
kubectl get aiinferenceservice,inferenceservice.serving.kserve.io,deploy,svc,scaledobjects.keda.sh,gateways.gateway.networking.k8s.io,backends.gateway.envoyproxy.io,aiservicebackends.aigateway.envoyproxy.io,aigatewayroutes.aigateway.envoyproxy.io -n default
```

Validate the predictor service:

```bash
kubectl port-forward -n default svc/autoscaled-echo-predictor 18080:80
curl http://127.0.0.1:18080/
```

Expected response:

```text
inference service ready
```

Validate the Envoy AI Gateway route. Kind usually leaves LoadBalancer services
with `<pending>` external IPs, so port-forward the Envoy service created for the
Gateway:

```bash
ENVOY_SERVICE="$(kubectl get svc -n envoy-gateway-system \
  --selector=gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=autoscaled-echo \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl port-forward -n envoy-gateway-system "svc/${ENVOY_SERVICE}" 18888:80
curl -H 'Host: autoscaled-echo.127.0.0.1.nip.io' http://127.0.0.1:18888/
```

## Custom Resource Shape

Minimal `AIInferenceService`:

```yaml
apiVersion: inference.ai/v1
kind: AIInferenceService
metadata:
  name: my-model
  namespace: default
spec:
  image: ghcr.io/example/inference-server:latest
  port: 8080
  replicas: 1
```

Common fields:

- `spec.image`: required serving image.
- `spec.port`: container port, defaults to `8080`.
- `spec.command` and `spec.args`: optional container entrypoint override.
- `spec.env`: optional container environment variables.
- `spec.resources`: Kubernetes requests and limits.
- `spec.model.uri`: exposed to the container as `MODEL_URI`.
- `spec.autoscaling`: enables KServe/KEDA autoscaling.
- `spec.ingress`: creates Gateway API and Envoy AI Gateway resources.
- `spec.accelerator`: adds accelerator limits, defaulting to `nvidia.com/gpu`.

## Cleanup

Delete sample workloads:

```bash
kubectl delete -f config/samples/inference_v1_inferenceservice_autoscaled.yaml
```

Remove the operator from the cluster:

```bash
kubectl delete -k config/default --ignore-not-found
```

Delete the Kind cluster:

```bash
kind delete cluster --name ai-inference-dev
docker rm -f kind-registry
```

If this repository installed its local Kind binary, use `bin/kind` instead of
`kind` for the delete command.

## Troubleshooting

If `go test ./...` fails with `go: command not found`, install Go 1.25 or newer.
Docker builds can still work because the build image contains Go.

If a Gateway is stuck with `Waiting for controller`, check that the GatewayClass
exists:

```bash
kubectl get gatewayclass envoy-gateway
```

Create it manually if needed:

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
```

If Envoy Gateway logs say `Backend is disabled in Envoy Gateway configuration`,
enable the Backend extension API and restart Envoy Gateway:

```bash
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

kubectl -n envoy-gateway-system rollout restart deployment/envoy-gateway
kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=180s
```

If the parent `AIInferenceService` is not Ready, inspect the child KServe object
and operator logs:

```bash
kubectl get inferenceservice -n default
kubectl describe inferenceservice autoscaled-echo -n default
kubectl logs -n ai-inference-operator-system \
  deployment/ai-inference-operator-controller-manager --tail=120
```

The Hugging Face samples are examples of a real model-serving shape. They may
need a valid access token, image-specific arguments, and enough CPU, memory, or
GPU capacity for the selected model.
