output "resource_group_name" {
  description = "Resource group containing the lab."
  value       = azurerm_resource_group.cluster.name
}

output "control_plane_public_ip" {
  description = "Public address used for administrative SSH and kube-apiserver access."
  value       = azurerm_public_ip.control_plane.ip_address
}

output "control_plane_private_ip" {
  description = "Stable kubeadm control-plane address inside the VNet."
  value       = azurerm_network_interface.control_plane.private_ip_address
}

output "gpu_worker_public_ip" {
  description = "Public address to place in the Cloudflare DNS A record."
  value       = azurerm_public_ip.gpu_worker.ip_address
}

output "gpu_worker_private_ip" {
  description = "Stable GPU worker address inside the VNet."
  value       = azurerm_network_interface.gpu_worker.private_ip_address
}

output "gpu_worker_fqdn" {
  description = "Azure-provided hostname useful before the custom DNS record exists."
  value       = azurerm_public_ip.gpu_worker.fqdn
}

output "gpu_worker_priority" {
  description = "Confirms whether the GPU worker uses Spot or regular capacity."
  value       = var.gpu_use_spot ? "Spot" : "Regular"
}

output "ssh_commands" {
  description = "Convenience commands for testing key-only SSH access."
  value = {
    control_plane = "ssh ${var.admin_username}@${azurerm_public_ip.control_plane.ip_address}"
    gpu_worker    = "ssh ${var.admin_username}@${azurerm_public_ip.gpu_worker.ip_address}"
  }
}
