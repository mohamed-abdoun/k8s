package v1

import (
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type AIInferenceServiceSpec struct {
	Image            string                         `json:"image"`
	Replicas         *int32                         `json:"replicas,omitempty"`
	Port             int32                          `json:"port,omitempty"`
	ServiceType      corev1.ServiceType             `json:"serviceType,omitempty"`
	Command          []string                       `json:"command,omitempty"`
	Args             []string                       `json:"args,omitempty"`
	Env              []corev1.EnvVar                `json:"env,omitempty"`
	Resources        corev1.ResourceRequirements    `json:"resources,omitempty"`
	Model            *ModelSpec                     `json:"model,omitempty"`
	Volumes          []corev1.Volume                `json:"volumes,omitempty"`
	VolumeMounts     []corev1.VolumeMount           `json:"volumeMounts,omitempty"`
	PodLabels        map[string]string              `json:"podLabels,omitempty"`
	PodAnnotations   map[string]string              `json:"podAnnotations,omitempty"`
	NodeSelector     map[string]string              `json:"nodeSelector,omitempty"`
	Tolerations      []corev1.Toleration            `json:"tolerations,omitempty"`
	Affinity         *corev1.Affinity               `json:"affinity,omitempty"`
	RuntimeClassName *string                        `json:"runtimeClassName,omitempty"`
	ImagePullSecrets []corev1.LocalObjectReference  `json:"imagePullSecrets,omitempty"`
	Autoscaling      *AutoscalingSpec               `json:"autoscaling,omitempty"`
	Ingress          *IngressSpec                   `json:"ingress,omitempty"`
	Accelerator      *AcceleratorSpec               `json:"accelerator,omitempty"`
	Strategy         *appDeploymentStrategyShortcut `json:"strategy,omitempty"`
}

type appDeploymentStrategyShortcut struct {
	Type           string `json:"type,omitempty"`
	MaxSurge       string `json:"maxSurge,omitempty"`
	MaxUnavailable string `json:"maxUnavailable,omitempty"`
}

type ModelSpec struct {
	URI       string `json:"uri,omitempty"`
	MountPath string `json:"mountPath,omitempty"`
}

type AutoscalingSpec struct {
	MinReplicas                    int32                                          `json:"minReplicas,omitempty"`
	MaxReplicas                    int32                                          `json:"maxReplicas,omitempty"`
	TargetCPUUtilizationPercentage *int32                                         `json:"targetCPUUtilizationPercentage,omitempty"`
	TargetMemoryAverageUtilization *int32                                         `json:"targetMemoryAverageUtilization,omitempty"`
	Behavior                       *autoscalingv2.HorizontalPodAutoscalerBehavior `json:"behavior,omitempty"`
}

type IngressSpec struct {
	Enabled       bool              `json:"enabled,omitempty"`
	Host          string            `json:"host,omitempty"`
	Path          string            `json:"path,omitempty"`
	ClassName     *string           `json:"className,omitempty"`
	TLSSecretName string            `json:"tlsSecretName,omitempty"`
	Annotations   map[string]string `json:"annotations,omitempty"`
}

type AcceleratorSpec struct {
	ResourceName corev1.ResourceName `json:"resourceName,omitempty"`
	Count        resource.Quantity   `json:"count,omitempty"`
}

type AIInferenceServiceStatus struct {
	ObservedGeneration int64              `json:"observedGeneration,omitempty"`
	Replicas           int32              `json:"replicas,omitempty"`
	ReadyReplicas      int32              `json:"readyReplicas,omitempty"`
	Endpoint           string             `json:"endpoint,omitempty"`
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
type AIInferenceService struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   AIInferenceServiceSpec   `json:"spec,omitempty"`
	Status AIInferenceServiceStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type AIInferenceServiceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []AIInferenceService `json:"items"`
}
