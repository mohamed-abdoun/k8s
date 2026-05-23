# Manual Test Guide

This guide lists the commands needed to deploy the AI Inference Operator and
manually smoke test an `AIInferenceService` on a local Kind cluster.

## 1. Confirm Tools

Run these commands from any directory:

```bash
docker version
kubectl version --client
helm version
go version
curl --version
```

Expected Go version:

```bash
go version
```

The version should be Go 1.25 or newer.

## 2. Start the Local Cluster

Run from the repository root:

```bash
hack/kind-up.sh
```

Confirm the cluster is selected:

```bash
kubectl config current-context
```

Expected context:

```text
kind-ai-inference-dev
```

Confirm nodes are ready:

```bash
kubectl get nodes
```

Confirm platform pods are running:

```bash
kubectl get pods -A
```

Confirm required CRDs exist:

```bash
kubectl get crd aiinferenceservices.inference.ai
kubectl get crd inferenceservices.serving.kserve.io
kubectl get crd scaledobjects.keda.sh
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get crd backends.gateway.envoyproxy.io
kubectl get crd aiservicebackends.aigateway.envoyproxy.io
kubectl get crd aigatewayroutes.aigateway.envoyproxy.io
```

Confirm Envoy Gateway is configured:

```bash
kubectl get gatewayclass envoy-gateway
kubectl get configmap envoy-gateway-config -n envoy-gateway-system -o yaml
```

## 3. Run Host Go Tests

Run from the repository root:

```bash
go test ./...
```

Expected result:

```text
?   	github.com/mohamed/ai-inference-operator/api/v1	[no test files]
?   	github.com/mohamed/ai-inference-operator/cmd/manager	[no test files]
?   	github.com/mohamed/ai-inference-operator/internal/controller	[no test files]
```

## 4. Build and Push the Operator Image

Run from the repository root:

```bash
docker build -t localhost:5001/ai-inference-operator:dev .
docker push localhost:5001/ai-inference-operator:dev
```

## 5. Deploy the Operator

Run from the repository root:

```bash
kubectl apply -k config/default
```

Wait for the controller to become ready:

```bash
kubectl rollout status deployment/ai-inference-operator-controller-manager \
  -n ai-inference-operator-system \
  --timeout=180s
```

Confirm the controller pod is running:

```bash
kubectl get pods -n ai-inference-operator-system
```

Check controller logs:

```bash
kubectl logs -n ai-inference-operator-system \
  deployment/ai-inference-operator-controller-manager \
  --tail=120
```

## 6. Deploy the Sample AIInferenceService

Apply the autoscaled echo sample:

```bash
kubectl apply -f config/samples/inference_v1_inferenceservice_autoscaled.yaml
```

Wait for the custom resource to become ready:

```bash
kubectl wait aiinferenceservice/autoscaled-echo \
  -n default \
  --for=condition=Ready \
  --timeout=300s
```

Check the custom resource:

```bash
kubectl get aiinferenceservice autoscaled-echo -n default -o wide
kubectl describe aiinferenceservice autoscaled-echo -n default
```

## 7. Confirm Child Resources

List all resources created for the sample:

```bash
kubectl get aiinferenceservice,inferenceservice.serving.kserve.io,deploy,svc,scaledobjects.keda.sh,gateways.gateway.networking.k8s.io,httproutes.gateway.networking.k8s.io,backends.gateway.envoyproxy.io,aiservicebackends.aigateway.envoyproxy.io,aigatewayroutes.aigateway.envoyproxy.io -n default
```

Confirm the KServe `InferenceService` is ready:

```bash
kubectl get inferenceservice autoscaled-echo -n default -o wide
```

Confirm the predictor Deployment is ready:

```bash
kubectl get deployment autoscaled-echo-predictor -n default
```

Confirm the predictor Service exists:

```bash
kubectl get service autoscaled-echo-predictor -n default
```

Confirm the KEDA ScaledObject exists:

```bash
kubectl get scaledobject autoscaled-echo-predictor -n default
```

Confirm the Envoy Backend uses service port `80`:

```bash
kubectl get backend autoscaled-echo \
  -n default \
  -o jsonpath='{.spec.endpoints[0].fqdn}{"\n"}'
```

Expected output:

```text
{"hostname":"autoscaled-echo-predictor.default.svc.cluster.local","port":80}
```

## 8. Smoke Test the Predictor Service

Open terminal 1:

```bash
kubectl port-forward -n default svc/autoscaled-echo-predictor 18080:80
```

Open terminal 2:

```bash
curl http://127.0.0.1:18080/
```

Expected response:

```text
inference service ready
```

Stop the port-forward in terminal 1 with `Ctrl+C`.

## 9. Smoke Test Through Envoy AI Gateway

Find the Envoy service created for the Gateway:

```bash
ENVOY_SERVICE="$(kubectl get svc -n envoy-gateway-system \
  --selector=gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=autoscaled-echo \
  -o jsonpath='{.items[0].metadata.name}')"

echo "${ENVOY_SERVICE}"
```

Open terminal 1:

```bash
kubectl port-forward -n envoy-gateway-system "svc/${ENVOY_SERVICE}" 18888:80
```

Open terminal 2:

```bash
curl -H 'Host: autoscaled-echo.127.0.0.1.nip.io' http://127.0.0.1:18888/
```

Expected response:

```text
inference service ready
```

Stop the port-forward in terminal 1 with `Ctrl+C`.

## 10. Check Logs During Testing

Operator logs:

```bash
kubectl logs -n ai-inference-operator-system \
  deployment/ai-inference-operator-controller-manager \
  --tail=120
```

KServe controller logs:

```bash
kubectl logs -n kserve deployment/kserve-controller-manager --tail=120
```

KEDA operator logs:

```bash
kubectl logs -n keda deployment/keda-operator --tail=120
```

Envoy Gateway logs:

```bash
kubectl logs -n envoy-gateway-system deployment/envoy-gateway --tail=120
```

Envoy AI Gateway logs:

```bash
kubectl logs -n envoy-ai-gateway-system deployment/ai-gateway-controller --tail=120
```

## 11. Restart After Rebuilding

If you rebuild and push `localhost:5001/ai-inference-operator:dev`, restart the
operator so it pulls the latest image:

```bash
docker build -t localhost:5001/ai-inference-operator:dev .
docker push localhost:5001/ai-inference-operator:dev

kubectl rollout restart deployment/ai-inference-operator-controller-manager \
  -n ai-inference-operator-system

kubectl rollout status deployment/ai-inference-operator-controller-manager \
  -n ai-inference-operator-system \
  --timeout=180s
```

Trigger a reconcile of the sample:

```bash
kubectl annotate aiinferenceservice autoscaled-echo \
  -n default \
  manual-test-reconcile="$(date +%s)" \
  --overwrite
```

## 12. Cleanup

Delete the sample:

```bash
kubectl delete -f config/samples/inference_v1_inferenceservice_autoscaled.yaml
```

Confirm sample resources are gone:

```bash
kubectl get aiinferenceservice,inferenceservice.serving.kserve.io,deploy,svc,scaledobjects.keda.sh,gateways.gateway.networking.k8s.io,httproutes.gateway.networking.k8s.io,backends.gateway.envoyproxy.io,aiservicebackends.aigateway.envoyproxy.io,aigatewayroutes.aigateway.envoyproxy.io -n default
```

Delete the operator:

```bash
kubectl delete -k config/default --ignore-not-found
```

Delete the Kind cluster:

```bash
kind delete cluster --name ai-inference-dev
```

Delete the local registry:

```bash
docker rm -f kind-registry
```
