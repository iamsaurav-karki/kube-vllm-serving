variable "location" {
  description = "Azure region for every resource."
  type        = string
  default     = "eastasia"
}

variable "resource_group_name" {
  description = "Resource group dedicated to the lab cluster."
  type        = string
  default     = "rg-kube-vllm-eastasia"
}

variable "name_prefix" {
  description = "Lowercase prefix used for resource names."
  type        = string
  default     = "kube-vllm"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.name_prefix))
    error_message = "name_prefix must contain 3-20 lowercase letters, digits, or hyphens."
  }
}

variable "admin_username" {
  description = "Administrative Linux user created on both VMs."
  type        = string
  default     = "sauravkarki"
}

variable "admin_cidr" {
  description = "Single public IPv4 CIDR allowed to use SSH and kube-apiserver."
  type        = string

  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.admin_cidr)) && can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a valid single-host IPv4 /32 CIDR."
  }
}

variable "ssh_public_key_path" {
  description = "Local path to the SSH public key installed on both VMs."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "control_plane_vm_size" {
  description = "Cost-minimized control-plane VM with 2 vCPU and 8 GB RAM."
  type        = string
  default     = "Standard_B2s_v2"
}

variable "gpu_worker_vm_size" {
  description = "Full 24 GB NVIDIA A10 GPU VM size."
  type        = string
  default     = "Standard_NV36ads_A10_v5"
}

variable "gpu_use_spot" {
  description = "Use interruptible Spot capacity for the replaceable GPU worker."
  type        = bool
  default     = true
}

variable "gpu_spot_max_price" {
  description = "Maximum hourly Spot price in USD; eviction occurs above this price."
  type        = number
  default     = 1.50

  validation {
    condition     = var.gpu_spot_max_price > 0
    error_message = "gpu_spot_max_price must be greater than zero."
  }
}

variable "vnet_cidr" {
  description = "Address range for the cluster VNet."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "Address range for the cluster node subnet."
  type        = string
  default     = "10.42.0.0/24"
}

variable "control_plane_private_ip" {
  description = "Stable control-plane address used by kubeadm."
  type        = string
  default     = "10.42.0.10"
}

variable "gpu_worker_private_ip" {
  description = "Stable GPU worker address used by the Ansible inventory."
  type        = string
  default     = "10.42.0.20"
}

variable "control_plane_os_disk_size_gb" {
  description = "Standard SSD size for the control plane."
  type        = number
  default     = 64
}

variable "gpu_worker_os_disk_size_gb" {
  description = "Standard SSD size for images, model cache, and Open WebUI data."
  type        = number
  default     = 256
}

variable "tags" {
  description = "Additional tags merged with the project tags."
  type        = map(string)
  default     = {}
}
