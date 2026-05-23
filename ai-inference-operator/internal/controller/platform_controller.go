package controller

import (
	"context"
	"fmt"
	"reflect"
	"time"

	inferencev1 "github.com/mohamed/ai-inference-operator/api/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

type AIInferenceServiceReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

func (r *AIInferenceServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var service inferencev1.AIInferenceService
	if err := r.Get(ctx, req.NamespacedName, &service); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	originalStatus := service.Status.DeepCopy()

	if service.Spec.Image == "" {
		r.setCondition(&service, "Ready", metav1.ConditionFalse, "InvalidSpec", "spec.image is required")
		_ = r.Status().Update(ctx, &service)
		return ctrl.Result{}, nil
	}

	if err := r.reconcileKServe(ctx, &service); err != nil {
		return ctrl.Result{}, err
	}
	if err := r.reconcileGateway(ctx, &service); err != nil {
		return ctrl.Result{}, err
	}
	if err := r.reconcileAIGateway(ctx, &service); err != nil {
		return ctrl.Result{}, err
	}

	ready, endpoint := r.kserveStatus(ctx, &service)
	service.Status.ObservedGeneration = service.Generation
	service.Status.Endpoint = endpoint
	if service.Status.Endpoint == "" {
		service.Status.Endpoint = gatewayEndpoint(&service)
	}
	if ready {
		r.setCondition(&service, "Ready", metav1.ConditionTrue, "PlatformReady", "KServe, KEDA, Gateway API, and AI Gateway resources reconciled")
	} else {
		r.setCondition(&service, "Ready", metav1.ConditionFalse, "WaitingForKServe", "platform resources reconciled; waiting for KServe readiness")
	}

	if !reflect.DeepEqual(originalStatus, &service.Status) {
		if err := r.Status().Update(ctx, &service); err != nil {
			if apierrors.IsConflict(err) {
				return ctrl.Result{Requeue: true}, nil
			}
			return ctrl.Result{}, err
		}
	}

	logger.Info("reconciled AI inference service", "endpoint", service.Status.Endpoint, "ready", ready)
	if !ready {
		return ctrl.Result{RequeueAfter: 15 * time.Second}, nil
	}
	return ctrl.Result{}, nil
}

func (r *AIInferenceServiceReconciler) reconcileKServe(ctx context.Context, service *inferencev1.AIInferenceService) error {
	obj := platformObject("serving.kserve.io/v1beta1", "InferenceService", service.Namespace, service.Name)
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, obj, func() error {
		if err := controllerutil.SetControllerReference(service, obj, r.Scheme); err != nil {
			return err
		}
		obj.SetLabels(workloadLabels(service))
		annotations := copyStringMap(service.Spec.PodAnnotations)
		annotations["serving.kserve.io/deploymentMode"] = "Standard"
		if service.Spec.Autoscaling != nil {
			annotations["serving.kserve.io/autoscalerClass"] = "keda"
		}
		obj.SetAnnotations(annotations)
		predictor := map[string]interface{}{
			"containers": []interface{}{kserveContainer(service)},
		}
		if len(service.Spec.PodLabels) > 0 {
			predictor["labels"] = stringMapToInterface(service.Spec.PodLabels)
		}
		if service.Spec.Replicas != nil && service.Spec.Autoscaling == nil {
			predictor["minReplicas"] = int64(*service.Spec.Replicas)
		}
		if service.Spec.Autoscaling != nil {
			minReplicas := maxInt32(1, service.Spec.Autoscaling.MinReplicas)
			maxReplicas := maxInt32(minReplicas, service.Spec.Autoscaling.MaxReplicas)
			target := int64(80)
			if service.Spec.Autoscaling.TargetCPUUtilizationPercentage != nil {
				target = int64(*service.Spec.Autoscaling.TargetCPUUtilizationPercentage)
			}
			predictor["minReplicas"] = int64(minReplicas)
			predictor["maxReplicas"] = int64(maxReplicas)
			predictor["autoScaling"] = map[string]interface{}{
				"metrics": []interface{}{map[string]interface{}{
					"type": "Resource",
					"resource": map[string]interface{}{
						"name": "cpu",
						"target": map[string]interface{}{
							"type":               "Utilization",
							"averageUtilization": target,
						},
					},
				}},
			}
		}
		if len(service.Spec.NodeSelector) > 0 {
			predictor["nodeSelector"] = stringMapToInterface(service.Spec.NodeSelector)
		}
		if service.Spec.RuntimeClassName != nil {
			predictor["runtimeClassName"] = *service.Spec.RuntimeClassName
		}
		return unstructured.SetNestedMap(obj.Object, map[string]interface{}{"predictor": predictor}, "spec")
	})
	return err
}

func (r *AIInferenceServiceReconciler) reconcileKEDA(ctx context.Context, service *inferencev1.AIInferenceService) error {
	obj := platformObject("keda.sh/v1alpha1", "ScaledObject", service.Namespace, service.Name)
	if service.Spec.Autoscaling == nil {
		return client.IgnoreNotFound(r.Delete(ctx, obj))
	}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, obj, func() error {
		if err := controllerutil.SetControllerReference(service, obj, r.Scheme); err != nil {
			return err
		}
		obj.SetLabels(workloadLabels(service))
		cpu := "80"
		if service.Spec.Autoscaling.TargetCPUUtilizationPercentage != nil {
			cpu = fmt.Sprintf("%d", *service.Spec.Autoscaling.TargetCPUUtilizationPercentage)
		}
		minReplicas := maxInt32(1, service.Spec.Autoscaling.MinReplicas)
		maxReplicas := maxInt32(minReplicas, service.Spec.Autoscaling.MaxReplicas)
		spec := map[string]interface{}{
			"scaleTargetRef": map[string]interface{}{
				"apiVersion": "apps/v1",
				"kind":       "Deployment",
				"name":       service.Name + "-predictor",
			},
			"minReplicaCount": int64(minReplicas),
			"maxReplicaCount": int64(maxReplicas),
			"triggers": []interface{}{map[string]interface{}{
				"type": "cpu",
				"metadata": map[string]interface{}{
					"type":  "Utilization",
					"value": cpu,
				},
			}},
		}
		return unstructured.SetNestedMap(obj.Object, spec, "spec")
	})
	return err
}

func (r *AIInferenceServiceReconciler) kedaTargetReady(ctx context.Context, service *inferencev1.AIInferenceService) (bool, error) {
	target := platformObject("apps/v1", "Deployment", service.Namespace, service.Name+"-predictor")
	if err := r.Get(ctx, client.ObjectKeyFromObject(target), target); err != nil {
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func (r *AIInferenceServiceReconciler) reconcileGateway(ctx context.Context, service *inferencev1.AIInferenceService) error {
	if service.Spec.Ingress == nil || !service.Spec.Ingress.Enabled {
		return nil
	}
	gateway := platformObject("gateway.networking.k8s.io/v1", "Gateway", service.Namespace, service.Name)
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, gateway, func() error {
		if err := controllerutil.SetControllerReference(service, gateway, r.Scheme); err != nil {
			return err
		}
		className := "envoy-gateway"
		if service.Spec.Ingress.ClassName != nil && *service.Spec.Ingress.ClassName != "" {
			className = *service.Spec.Ingress.ClassName
		}
		spec := map[string]interface{}{
			"gatewayClassName": className,
			"listeners": []interface{}{map[string]interface{}{
				"name":     "http",
				"protocol": "HTTP",
				"port":     int64(80),
				"hostname": service.Spec.Ingress.Host,
				"allowedRoutes": map[string]interface{}{
					"namespaces": map[string]interface{}{"from": "Same"},
				},
			}},
		}
		return unstructured.SetNestedMap(gateway.Object, spec, "spec")
	})
	return err
}

func (r *AIInferenceServiceReconciler) reconcileAIGateway(ctx context.Context, service *inferencev1.AIInferenceService) error {
	if service.Spec.Ingress == nil || !service.Spec.Ingress.Enabled {
		return nil
	}
	if err := r.reconcileEnvoyBackend(ctx, service); err != nil {
		return err
	}
	if err := r.reconcileAIServiceBackend(ctx, service); err != nil {
		return err
	}
	route := platformObject("aigateway.envoyproxy.io/v1beta1", "AIGatewayRoute", service.Namespace, service.Name)
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, route, func() error {
		if err := controllerutil.SetControllerReference(service, route, r.Scheme); err != nil {
			return err
		}
		route.SetLabels(workloadLabels(service))
		spec := map[string]interface{}{
			"parentRefs": []interface{}{map[string]interface{}{
				"group": "gateway.networking.k8s.io",
				"kind":  "Gateway",
				"name":  service.Name,
			}},
			"rules": []interface{}{map[string]interface{}{
				"backendRefs":   []interface{}{map[string]interface{}{"name": service.Name}},
				"modelsOwnedBy": "ai-inference-operator",
			}},
			"llmRequestCosts": []interface{}{
				map[string]interface{}{"metadataKey": "llm_input_token", "type": "InputToken"},
				map[string]interface{}{"metadataKey": "llm_output_token", "type": "OutputToken"},
				map[string]interface{}{"metadataKey": "llm_total_token", "type": "TotalToken"},
			},
		}
		return unstructured.SetNestedMap(route.Object, spec, "spec")
	})
	return err
}

func (r *AIInferenceServiceReconciler) reconcileEnvoyBackend(ctx context.Context, service *inferencev1.AIInferenceService) error {
	obj := platformObject("gateway.envoyproxy.io/v1alpha1", "Backend", service.Namespace, service.Name)
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, obj, func() error {
		if err := controllerutil.SetControllerReference(service, obj, r.Scheme); err != nil {
			return err
		}
		obj.SetLabels(workloadLabels(service))
		spec := map[string]interface{}{
			"type": "Endpoints",
			"endpoints": []interface{}{map[string]interface{}{
				"fqdn": map[string]interface{}{
					"hostname": fmt.Sprintf("%s-predictor.%s.svc.cluster.local", service.Name, service.Namespace),
					// KServe's predictor Service exposes HTTP on port 80 and forwards
					// to the user-specified container port.
					"port": int64(80),
				},
			}},
		}
		return unstructured.SetNestedMap(obj.Object, spec, "spec")
	})
	return err
}

func (r *AIInferenceServiceReconciler) reconcileAIServiceBackend(ctx context.Context, service *inferencev1.AIInferenceService) error {
	obj := platformObject("aigateway.envoyproxy.io/v1beta1", "AIServiceBackend", service.Namespace, service.Name)
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, obj, func() error {
		if err := controllerutil.SetControllerReference(service, obj, r.Scheme); err != nil {
			return err
		}
		obj.SetLabels(workloadLabels(service))
		spec := map[string]interface{}{
			"backendRef": map[string]interface{}{
				"group": "gateway.envoyproxy.io",
				"kind":  "Backend",
				"name":  service.Name,
			},
			"schema": map[string]interface{}{"name": "OpenAI", "prefix": "/v1"},
		}
		return unstructured.SetNestedMap(obj.Object, spec, "spec")
	})
	return err
}

func (r *AIInferenceServiceReconciler) kserveStatus(ctx context.Context, service *inferencev1.AIInferenceService) (bool, string) {
	obj := platformObject("serving.kserve.io/v1beta1", "InferenceService", service.Namespace, service.Name)
	if err := r.Get(ctx, client.ObjectKeyFromObject(obj), obj); err != nil {
		return false, ""
	}
	endpoint, _, _ := unstructured.NestedString(obj.Object, "status", "url")
	conditions, _, _ := unstructured.NestedSlice(obj.Object, "status", "conditions")
	for _, item := range conditions {
		condition, ok := item.(map[string]interface{})
		if ok && condition["type"] == "Ready" && condition["status"] == "True" {
			return true, endpoint
		}
	}
	return false, endpoint
}

func (r *AIInferenceServiceReconciler) setCondition(service *inferencev1.AIInferenceService, conditionType string, status metav1.ConditionStatus, reason string, message string) {
	meta.SetStatusCondition(&service.Status.Conditions, metav1.Condition{
		Type:               conditionType,
		Status:             status,
		ObservedGeneration: service.Generation,
		Reason:             reason,
		Message:            message,
	})
}

func (r *AIInferenceServiceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&inferencev1.AIInferenceService{}).
		Complete(r)
}

func platformObject(apiVersion, kind, namespace, name string) *unstructured.Unstructured {
	obj := &unstructured.Unstructured{}
	gv, err := schema.ParseGroupVersion(apiVersion)
	if err == nil {
		obj.SetGroupVersionKind(gv.WithKind(kind))
	} else {
		obj.SetAPIVersion(apiVersion)
		obj.SetKind(kind)
	}
	obj.SetNamespace(namespace)
	obj.SetName(name)
	return obj
}

func kserveContainer(service *inferencev1.AIInferenceService) map[string]interface{} {
	container := map[string]interface{}{
		"name":  "kserve-container",
		"image": service.Spec.Image,
		"ports": []interface{}{map[string]interface{}{
			"containerPort": int64(servicePort(service)),
			"protocol":      "TCP",
		}},
	}
	if len(service.Spec.Command) > 0 {
		container["command"] = stringSliceToInterface(service.Spec.Command)
	}
	if len(service.Spec.Args) > 0 {
		container["args"] = stringSliceToInterface(service.Spec.Args)
	}
	if len(service.Spec.Env) > 0 || service.Spec.Model != nil {
		container["env"] = toUnstructured(buildEnv(service))
	}
	if len(service.Spec.VolumeMounts) > 0 {
		container["volumeMounts"] = toUnstructured(service.Spec.VolumeMounts)
	}
	if len(service.Spec.Resources.Limits) > 0 || len(service.Spec.Resources.Requests) > 0 {
		container["resources"] = toUnstructured(service.Spec.Resources)
	}
	return container
}

func toUnstructured(value interface{}) interface{} {
	out, err := runtime.DefaultUnstructuredConverter.ToUnstructured(value)
	if err != nil {
		return nil
	}
	return out
}

func stringSliceToInterface(in []string) []interface{} {
	out := make([]interface{}, 0, len(in))
	for _, value := range in {
		out = append(out, value)
	}
	return out
}

func stringMapToInterface(in map[string]string) map[string]interface{} {
	out := make(map[string]interface{}, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}

func maxInt32(a, b int32) int32 {
	if a > b {
		return a
	}
	return b
}

func gatewayEndpoint(service *inferencev1.AIInferenceService) string {
	if service.Spec.Ingress == nil || !service.Spec.Ingress.Enabled || service.Spec.Ingress.Host == "" {
		return ""
	}
	path := service.Spec.Ingress.Path
	if path == "" {
		path = "/"
	}
	return fmt.Sprintf("http://%s%s", service.Spec.Ingress.Host, path)
}
