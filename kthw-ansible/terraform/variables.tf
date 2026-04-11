variable "cluster_name" {
  description = "Cluster name prefix applied to all libvirt resources"
  type        = string
  default     = "k8s-hardway"
}

variable "subnet" {
  description = "First three octets of the /24 management network (e.g. '192.168.56')"
  type        = string
  default     = "192.168.56"
}

variable "lb_last_octet" {
  description = "Last octet for the load-balancer VM"
  type        = number
  default     = 10
}

variable "masters_first_octet" {
  description = "Last octet of the first master node; subsequent masters increment by 1"
  type        = number
  default     = 11
}

variable "workers_first_octet" {
  description = "Last octet of the first worker node; subsequent workers increment by 1"
  type        = number
  default     = 21
}

variable "masters_count" {
  description = "Number of control-plane nodes (odd number recommended for etcd quorum)"
  type        = number
  default     = 2
}

variable "workers_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "masters_cpus" {
  type    = number
  default = 2
}

variable "masters_memory" {
  description = "Memory in MiB"
  type        = number
  default     = 2048
}

variable "workers_cpus" {
  type    = number
  default = 2
}

variable "workers_memory" {
  description = "Memory in MiB"
  type        = number
  default     = 2048
}

variable "lb_cpus" {
  type    = number
  default = 1
}

variable "lb_memory" {
  description = "Memory in MiB"
  type        = number
  default     = 512
}

variable "ubuntu_image_url" {
  description = "Ubuntu 24.04 cloud image URL. up.sh sets this automatically based on host arch."
  type        = string
  # Default to amd64; up.sh overrides this with the correct arch at runtime.
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ubuntu_image_path" {
  description = "Local path to cache the downloaded base image (avoids re-download)"
  type        = string
  default     = "/var/lib/libvirt/images/ubuntu-24.04-base.qcow2"
}

variable "arch" {
  description = "Target VM architecture: amd64 or arm64. Used for documentation/tagging only; image URL controls the actual arch."
  type        = string
  default     = "amd64"
}

variable "libvirt_pool" {
  description = "libvirt storage pool to use"
  type        = string
  default     = "k8s"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key injected into every VM via cloud-init"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}
