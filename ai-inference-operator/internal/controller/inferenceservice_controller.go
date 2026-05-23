package controller

import (
	"context"
	"fmt"
	"reflect"

	inferencev1 "github.com/mohamed/ai-inference-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

type LegacyAIInferenceServiceReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

func (r *LegacyAIInferenceServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var inferenceService inferencev1.AIInferenceService
	if err := r.Get(ctx, req.NamespacedName, &inferenceService); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	originalStatus := inferenceService.Status.DeepCopy()

	if inferenceService.Spec.Image == "" {
		r.setCondition(&inferenceService, "Ready", metav1.ConditionFalse, "InvalidSpec", "spec.image is required")
		_ = r.Status().Update(ctx, &inferenceService)
		return ctrl.Result{}, nil
	}

	deployment, err := r.reconcileDeployment(ctx, &inferenceService)
	if err != nil {
		return ctrl.Result{}, err
	}
	service, err := r.reconcileService(ctx, &inferenceService)
	if err != nil {
		return ctrl.Result{}, err
	}
	if err := r.reconcileHPA(ctx, &inferenceService); err != nil {
		return ctrl.Result{}, err
	}
	if err := r.reconcileIngress(ctx, &inferenceService); err != nil {
		return ctrl.Result{}, err
	}
	if err := r.reconcileModelConfigMap(ctx, &inferenceService); err != nil {
		return ctrl.Result{}, err
	}

	ready := deployment.Status.ReadyReplicas
	desired := deployment.Status.Replicas
	if desired == 0 && inferenceService.Spec.Replicas != nil {
		desired = *inferenceService.Spec.Replicas
	}

	conditionStatus := metav1.ConditionFalse
	reason := "DeploymentNotReady"
	message := fmt.Sprintf("%d/%d replicas are ready", ready, desired)
	if desired == ready && desired > 0 {
		conditionStatus = metav1.ConditionTrue
		reason = "Ready"
		message = "all replicas are ready"
	}

	endpoint := serviceEndpoint(&inferenceService, service)
	inferenceService.Status.ObservedGeneration = inferenceService.Generation
	inferenceService.Status.ReadyReplicas = ready
	inferenceService.Status.Replicas = desired
	inferenceService.Status.Endpoint = endpoint
	r.setCondition(&inferenceService, "Ready", conditionStatus, reason, message)
	if !reflect.DeepEqual(originalStatus, &inferenceService.Status) {
		if err := r.Status().Update(ctx, &inferenceService); err != nil {
			if apierrors.IsConflict(err) {
				return ctrl.Result{Requeue: true}, nil
			}
			return ctrl.Result{}, err
		}
	}

	logger.Info("reconciled inference service", "endpoint", endpoint, "readyReplicas", ready)
	return ctrl.Result{}, nil
}

func (r *LegacyAIInferenceServiceReconciler) reconcileDeployment(ctx context.Context, inferenceService *inferencev1.AIInferenceService) (*appsv1.Deployment, error) {
	deployment := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: inferenceService.Name, Namespace: inferenceService.Namespace}}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		if err := controllerutil.SetControllerReference(inferenceService, deployment, r.Scheme); err != nil {
			return err
		}

		labels := workloadLabels(inferenceService)
		selector := selectorLabels(inferenceService)
		replicas := int32(1)
		if inferenceService.Spec.Replicas != nil {
			replicas = *inferenceService.Spec.Replicas
		}
		if inferenceService.Spec.Autoscaling != nil {
			deployment.Spec.Replicas = nil
		} else {
			deployment.Spec.Replicas = &replicas
		}

		deployment.Labels = labels
		deployment.Spec.Selector = &metav1.LabelSelector{MatchLabels: selector}
		deployment.Spec.Template.Labels = mergeStringMap(labels, inferenceService.Spec.PodLabels)
		deployment.Spec.Template.Annotations = copyStringMap(inferenceService.Spec.PodAnnotations)
		deployment.Spec.Template.Spec.NodeSelector = copyStringMap(inferenceService.Spec.NodeSelector)
		deployment.Spec.Template.Spec.Tolerations = append([]corev1.Toleration(nil), inferenceService.Spec.Tolerations...)
		deployment.Spec.Template.Spec.Affinity = inferenceService.Spec.Affinity
		deployment.Spec.Template.Spec.RuntimeClassName = inferenceService.Spec.RuntimeClassName
		deployment.Spec.Template.Spec.ImagePullSecrets = append([]corev1.LocalObjectReference(nil), inferenceService.Spec.ImagePullSecrets...)
		deployment.Spec.Template.Spec.Volumes = append([]corev1.Volume(nil), inferenceService.Spec.Volumes...)

		container := corev1.Container{
			Name:            "server",
			Image:           inferenceService.Spec.Image,
			ImagePullPolicy: corev1.PullIfNotPresent,
			Command:         append([]string(nil), inferenceService.Spec.Command...),
			Args:            append([]string(nil), inferenceService.Spec.Args...),
			Env:             buildEnv(inferenceService),
			Resources:       *inferenceService.Spec.Resources.DeepCopy(),
			VolumeMounts:    append([]corev1.VolumeMount(nil), inferenceService.Spec.VolumeMounts...),
			Ports: []corev1.ContainerPort{{
				Name:          "http",
				ContainerPort: servicePort(inferenceService),
				Protocol:      corev1.ProtocolTCP,
			}},
			ReadinessProbe: httpProbe("/ready", servicePort(inferenceService)),
			LivenessProbe:  httpProbe("/healthz", servicePort(inferenceService)),
		}
		applyAccelerator(inferenceService, &container)
		deployment.Spec.Template.Spec.Containers = []corev1.Container{container}
		return nil
	})
	return deployment, err
}

func (r *LegacyAIInferenceServiceReconciler) reconcileService(ctx context.Context, inferenceService *inferencev1.AIInferenceService) (*corev1.Service, error) {
	service := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: inferenceService.Name, Namespace: inferenceService.Namespace}}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, service, func() error {
		if err := controllerutil.SetControllerReference(inferenceService, service, r.Scheme); err != nil {
			return err
		}
		service.Labels = workloadLabels(inferenceService)
		service.Spec.Selector = selectorLabels(inferenceService)
		service.Spec.Type = inferenceService.Spec.ServiceType
		if service.Spec.Type == "" {
			service.Spec.Type = corev1.ServiceTypeClusterIP
		}
		service.Spec.Ports = []corev1.ServicePort{{
			Name:       "http",
			Port:       servicePort(inferenceService),
			TargetPort: intstr.FromString("http"),
			Protocol:   corev1.ProtocolTCP,
		}}
		return nil
	})
	return service, err
}

func (r *LegacyAIInferenceServiceReconciler) reconcileHPA(ctx context.Context, inferenceService *inferencev1.AIInferenceService) error {
	hpa := &autoscalingv2.HorizontalPodAutoscaler{ObjectMeta: metav1.ObjectMeta{Name: inferenceService.Name, Namespace: inferenceService.Namespace}}
	key := types.NamespacedName{Name: inferenceService.Name, Namespace: inferenceService.Namespace}
	if inferenceService.Spec.Autoscaling == nil {
		return deleteIfExists(ctx, r.Client, key, hpa)
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, hpa, func() error {
		if err := controllerutil.SetControllerReference(inferenceService, hpa, r.Scheme); err != nil {
			return err
		}
		minReplicas := inferenceService.Spec.Autoscaling.MinReplicas
		if minReplicas == 0 {
			minReplicas = 1
		}
		maxReplicas := inferenceService.Spec.Autoscaling.MaxReplicas
		if maxReplicas < minReplicas {
			maxReplicas = minReplicas
		}

		hpa.Labels = workloadLabels(inferenceService)
		hpa.Spec.ScaleTargetRef = autoscalingv2.CrossVersionObjectReference{
			APIVersion: "apps/v1",
			Kind:       "Deployment",
			Name:       inferenceService.Name,
		}
		hpa.Spec.MinReplicas = &minReplicas
		hpa.Spec.MaxReplicas = maxReplicas
		hpa.Spec.Metrics = hpaMetrics(inferenceService.Spec.Autoscaling)
		hpa.Spec.Behavior = inferenceService.Spec.Autoscaling.Behavior
		return nil
	})
	return err
}

func (r *LegacyAIInferenceServiceReconciler) reconcileIngress(ctx context.Context, inferenceService *inferencev1.AIInferenceService) error {
	ingress := &networkingv1.Ingress{ObjectMeta: metav1.ObjectMeta{Name: inferenceService.Name, Namespace: inferenceService.Namespace}}
	key := types.NamespacedName{Name: inferenceService.Name, Namespace: inferenceService.Namespace}
	if inferenceService.Spec.Ingress == nil || !inferenceService.Spec.Ingress.Enabled {
		return deleteIfExists(ctx, r.Client, key, ingress)
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, ingress, func() error {
		if err := controllerutil.SetControllerReference(inferenceService, ingress, r.Scheme); err != nil {
			return err
		}
		path := inferenceService.Spec.Ingress.Path
		if path == "" {
			path = "/"
		}
		pathType := networkingv1.PathTypePrefix
		ingress.Labels = workloadLabels(inferenceService)
		ingress.Annotations = copyStringMap(inferenceService.Spec.Ingress.Annotations)
		ingress.Spec.IngressClassName = inferenceService.Spec.Ingress.ClassName
		ingress.Spec.Rules = []networkingv1.IngressRule{{
			Host: inferenceService.Spec.Ingress.Host,
			IngressRuleValue: networkingv1.IngressRuleValue{
				HTTP: &networkingv1.HTTPIngressRuleValue{
					Paths: []networkingv1.HTTPIngressPath{{
						Path:     path,
						PathType: &pathType,
						Backend: networkingv1.IngressBackend{
							Service: &networkingv1.IngressServiceBackend{
								Name: inferenceService.Name,
								Port: networkingv1.ServiceBackendPort{Name: "http"},
							},
						},
					}},
				},
			},
		}}
		if inferenceService.Spec.Ingress.TLSSecretName != "" {
			ingress.Spec.TLS = []networkingv1.IngressTLS{{
				Hosts:      []string{inferenceService.Spec.Ingress.Host},
				SecretName: inferenceService.Spec.Ingress.TLSSecretName,
			}}
		} else {
			ingress.Spec.TLS = nil
		}
		return nil
	})
	return err
}

func (r *LegacyAIInferenceServiceReconciler) reconcileModelConfigMap(ctx context.Context, inferenceService *inferencev1.AIInferenceService) error {
	configMap := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: modelConfigMapName(inferenceService), Namespace: inferenceService.Namespace}}
	key := types.NamespacedName{Name: modelConfigMapName(inferenceService), Namespace: inferenceService.Namespace}
	if inferenceService.Spec.Model == nil || inferenceService.Spec.Model.URI == "" {
		return deleteIfExists(ctx, r.Client, key, configMap)
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, configMap, func() error {
		if err := controllerutil.SetControllerReference(inferenceService, configMap, r.Scheme); err != nil {
			return err
		}
		configMap.Labels = workloadLabels(inferenceService)
		configMap.Data = map[string]string{"MODEL_URI": inferenceService.Spec.Model.URI}
		return nil
	})
	return err
}

func (r *LegacyAIInferenceServiceReconciler) setCondition(inferenceService *inferencev1.AIInferenceService, conditionType string, status metav1.ConditionStatus, reason string, message string) {
	meta.SetStatusCondition(&inferenceService.Status.Conditions, metav1.Condition{
		Type:               conditionType,
		Status:             status,
		ObservedGeneration: inferenceService.Generation,
		Reason:             reason,
		Message:            message,
	})
}

func (r *LegacyAIInferenceServiceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&inferencev1.AIInferenceService{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Owns(&autoscalingv2.HorizontalPodAutoscaler{}).
		Owns(&networkingv1.Ingress{}).
		Owns(&corev1.ConfigMap{}).
		Complete(r)
}
