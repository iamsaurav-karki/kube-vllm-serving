resource "azurerm_linux_virtual_machine" "control_plane" {
  name                            = "${var.name_prefix}-control-plane"
  computer_name                   = "kube-control"
  resource_group_name             = azurerm_resource_group.cluster.name
  location                        = azurerm_resource_group.cluster.location
  size                            = var.control_plane_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.control_plane.id]
  tags                            = merge(local.common_tags, { role = "control-plane" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "${var.name_prefix}-control-plane-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.control_plane_os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {}

  depends_on = [azurerm_network_interface_security_group_association.control_plane]
}

resource "azurerm_linux_virtual_machine" "gpu_worker" {
  name                            = "${var.name_prefix}-gpu-worker"
  computer_name                   = "kube-gpu-worker"
  resource_group_name             = azurerm_resource_group.cluster.name
  location                        = azurerm_resource_group.cluster.location
  size                            = var.gpu_worker_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.gpu_worker.id]
  priority                        = var.gpu_use_spot ? "Spot" : "Regular"
  eviction_policy                 = var.gpu_use_spot ? "Deallocate" : null
  max_bid_price                   = var.gpu_use_spot ? var.gpu_spot_max_price : null
  tags = merge(local.common_tags, {
    role     = "gpu-worker"
    priority = var.gpu_use_spot ? "spot" : "regular"
  })

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "${var.name_prefix}-gpu-worker-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.gpu_worker_os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {}

  depends_on = [azurerm_network_interface_security_group_association.gpu_worker]
}
