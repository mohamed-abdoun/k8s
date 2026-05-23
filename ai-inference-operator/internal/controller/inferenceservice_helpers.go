package controller

import (
	"context"
	"fmt"

	inferencev1 "github.com/mohamed/ai-inference-operator/api/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func selectorLabels(inferenceService *inferencev1.AIInferenceService) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":     "ai-inference",
		"app.kubernetes.io/instance": inferenceService.Name,
	}
}

func workloadLabels(inferenceService *inferencev1.AIInferenceService) map[string]string {
	labels := selectorLabels(inferenceService)
	labels["app.kubernetes.io/managed-by"] = "ai-inference-operator"
	labels["app.kubernetes.io/part-of"] = "ai-inference"
	return labels
}

func servicePort(inferenceService *inferencev1.AIInferenceService) int32 {
	if inferenceService.Spec.Port > 0 {
		return inferenceService.Spec.Port
	}
	return 8080
}

func httpProbe(path string, port int32) *corev1.Probe {
	return &corev1.Probe{
		ProbeHandler: corev1.ProbeHandler{
			HTTPGet: &corev1.HTTPGetAction{
				Path: path,
				Port: intstrFromInt32(port),
			},
		},
		InitialDelaySeconds: 10,
		PeriodSeconds:       10,
		FailureThreshold:    6,
	}
}

func intstrFromInt32(port int32) intstr.IntOrString {
	return intstr.FromInt32(port)
}

func buildEnv(inferenceService *inferencev1.AIInferenceService) []corev1.EnvVar {
	env := append([]corev1.EnvVar(nil), inferenceService.Spec.Env...)
	if inferenceService.Spec.Model != nil {
		if inferenceService.Spec.Model.URI != "" {
			env = append(env, corev1.EnvVar{Name: "MODEL_URI", Value: inferenceService.Spec.Model.URI})
		}
		if inferenceService.Spec.Model.MountPath != "" {
			env = append(env, corev1.EnvVar{Name: "MODEL_MOUNT_PATH", Value: inferenceService.Spec.Model.MountPath})
		}
	}
	return env
}

func applyAccelerator(inferenceService *inferencev1.AIInferenceService, container *corev1.Container) {
	if inferenceService.Spec.Accelerator == nil {
		return
	}
	name := inferenceService.Spec.Accelerator.ResourceName
	if name == "" {
		name = "nvidia.com/gpu"
	}
	count := inferenceService.Spec.Accelerator.Count
	if count.IsZero() {
		count = resource.MustParse("1")
	}
	if container.Resources.Limits == nil {
		container.Resources.Limits = corev1.ResourceList{}
	}
	container.Resources.Limits[name] = count
}

func hpaMetrics(spec *inferencev1.AutoscalingSpec) []autoscalingv2.MetricSpec {
	metrics := []autoscalingv2.MetricSpec{}
	if spec.TargetCPUUtilizationPercentage != nil {
		metrics = append(metrics, autoscalingv2.MetricSpec{
			Type: autoscalingv2.ResourceMetricSourceType,
			Resource: &autoscalingv2.ResourceMetricSource{
				Name: corev1.ResourceCPU,
				Target: autoscalingv2.MetricTarget{
					Type:               autoscalingv2.UtilizationMetricType,
					AverageUtilization: spec.TargetCPUUtilizationPercentage,
				},
			},
		})
	}
	if spec.TargetMemoryAverageUtilization != nil {
		metrics = append(metrics, autoscalingv2.MetricSpec{
			Type: autoscalingv2.ResourceMetricSourceType,
			Resource: &autoscalingv2.ResourceMetricSource{
				Name: corev1.ResourceMemory,
				Target: autoscalingv2.MetricTarget{
					Type:               autoscalingv2.UtilizationMetricType,
					AverageUtilization: spec.TargetMemoryAverageUtilization,
				},
			},
		})
	}
	if len(metrics) == 0 {
		cpu := int32(80)
		metrics = append(metrics, autoscalingv2.MetricSpec{
			Type: autoscalingv2.ResourceMetricSourceType,
			Resource: &autoscalingv2.ResourceMetricSource{
				Name: corev1.ResourceCPU,
				Target: autoscalingv2.MetricTarget{
					Type:               autoscalingv2.UtilizationMetricType,
					AverageUtilization: &cpu,
				},
			},
		})
	}
	return metrics
}

func serviceEndpoint(inferenceService *inferencev1.AIInferenceService, service *corev1.Service) string {
	if inferenceService.Spec.Ingress != nil && inferenceService.Spec.Ingress.Enabled && inferenceService.Spec.Ingress.Host != "" {
		scheme := "http"
		if inferenceService.Spec.Ingress.TLSSecretName != "" {
			scheme = "https"
		}
		path := inferenceService.Spec.Ingress.Path
		if path == "" {
			path = "/"
		}
		return fmt.Sprintf("%s://%s%s", scheme, inferenceService.Spec.Ingress.Host, path)
	}
	return fmt.Sprintf("http://%s.%s.svc:%d", service.Name, service.Namespace, servicePort(inferenceService))
}

func modelConfigMapName(inferenceService *inferencev1.AIInferenceService) string {
	return inferenceService.Name + "-model"
}

func deleteIfExists(ctx context.Context, c client.Client, key client.ObjectKey, object client.Object) error {
	if err := c.Get(ctx, key, object); err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}
	return client.IgnoreNotFound(c.Delete(ctx, object))
}

func mergeStringMap(base map[string]string, overlays ...map[string]string) map[string]string {
	out := copyStringMap(base)
	for _, overlay := range overlays {
		for key, value := range overlay {
			out[key] = value
		}
	}
	return out
}

func copyStringMap(in map[string]string) map[string]string {
	if in == nil {
		return map[string]string{}
	}
	out := make(map[string]string, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}
