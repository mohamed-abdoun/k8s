package v1

import (
	runtime "k8s.io/apimachinery/pkg/runtime"
)

func (in *AIInferenceService) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(AIInferenceService)
	*out = *in
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec = *in.Spec.DeepCopy()
	out.Status = *in.Status.DeepCopy()
	return out
}

func (in *AIInferenceServiceList) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(AIInferenceServiceList)
	*out = *in
	out.ListMeta = in.ListMeta
	if in.Items != nil {
		out.Items = make([]AIInferenceService, len(in.Items))
		for i := range in.Items {
			out.Items[i] = *in.Items[i].DeepCopyObject().(*AIInferenceService)
		}
	}
	return out
}

func (in *AIInferenceServiceSpec) DeepCopy() *AIInferenceServiceSpec {
	if in == nil {
		return nil
	}
	out := new(AIInferenceServiceSpec)
	*out = *in
	if in.Replicas != nil {
		out.Replicas = new(int32)
		*out.Replicas = *in.Replicas
	}
	out.Resources = *in.Resources.DeepCopy()
	if in.Model != nil {
		out.Model = &ModelSpec{URI: in.Model.URI, MountPath: in.Model.MountPath}
	}
	if in.Autoscaling != nil {
		out.Autoscaling = in.Autoscaling.DeepCopy()
	}
	if in.Ingress != nil {
		out.Ingress = in.Ingress.DeepCopy()
	}
	if in.Accelerator != nil {
		out.Accelerator = in.Accelerator.DeepCopy()
	}
	if in.Affinity != nil {
		out.Affinity = in.Affinity.DeepCopy()
	}
	if in.RuntimeClassName != nil {
		out.RuntimeClassName = new(string)
		*out.RuntimeClassName = *in.RuntimeClassName
	}
	if in.Strategy != nil {
		out.Strategy = &appDeploymentStrategyShortcut{
			Type:           in.Strategy.Type,
			MaxSurge:       in.Strategy.MaxSurge,
			MaxUnavailable: in.Strategy.MaxUnavailable,
		}
	}
	out.Command = append([]string(nil), in.Command...)
	out.Args = append([]string(nil), in.Args...)
	out.Env = append(in.Env[:0:0], in.Env...)
	out.Volumes = append(in.Volumes[:0:0], in.Volumes...)
	out.VolumeMounts = append(in.VolumeMounts[:0:0], in.VolumeMounts...)
	out.Tolerations = append(in.Tolerations[:0:0], in.Tolerations...)
	out.ImagePullSecrets = append(in.ImagePullSecrets[:0:0], in.ImagePullSecrets...)
	out.PodLabels = copyStringMap(in.PodLabels)
	out.PodAnnotations = copyStringMap(in.PodAnnotations)
	out.NodeSelector = copyStringMap(in.NodeSelector)
	return out
}

func (in *AIInferenceServiceStatus) DeepCopy() *AIInferenceServiceStatus {
	if in == nil {
		return nil
	}
	out := new(AIInferenceServiceStatus)
	*out = *in
	out.Conditions = append(in.Conditions[:0:0], in.Conditions...)
	return out
}

func (in *AutoscalingSpec) DeepCopy() *AutoscalingSpec {
	if in == nil {
		return nil
	}
	out := new(AutoscalingSpec)
	*out = *in
	if in.TargetCPUUtilizationPercentage != nil {
		out.TargetCPUUtilizationPercentage = new(int32)
		*out.TargetCPUUtilizationPercentage = *in.TargetCPUUtilizationPercentage
	}
	if in.TargetMemoryAverageUtilization != nil {
		out.TargetMemoryAverageUtilization = new(int32)
		*out.TargetMemoryAverageUtilization = *in.TargetMemoryAverageUtilization
	}
	if in.Behavior != nil {
		out.Behavior = in.Behavior.DeepCopy()
	}
	return out
}

func (in *IngressSpec) DeepCopy() *IngressSpec {
	if in == nil {
		return nil
	}
	out := new(IngressSpec)
	*out = *in
	if in.ClassName != nil {
		out.ClassName = new(string)
		*out.ClassName = *in.ClassName
	}
	out.Annotations = copyStringMap(in.Annotations)
	return out
}

func (in *AcceleratorSpec) DeepCopy() *AcceleratorSpec {
	if in == nil {
		return nil
	}
	out := new(AcceleratorSpec)
	*out = *in
	out.Count = in.Count.DeepCopy()
	return out
}

func copyStringMap(in map[string]string) map[string]string {
	if in == nil {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
