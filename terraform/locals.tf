locals {
  common_tags = merge(
    {
      project     = "kube-vllm-serving"
      environment = "portfolio-lab"
      managed_by  = "terraform"
      cost_owner  = var.admin_username
    },
    var.tags
  )
}
