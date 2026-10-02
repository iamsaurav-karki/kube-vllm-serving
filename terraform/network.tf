resource "azurerm_resource_group" "cluster" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "cluster" {
  name                = "${var.name_prefix}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.cluster.location
  resource_group_name = azurerm_resource_group.cluster.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "nodes"
  resource_group_name  = azurerm_resource_group.cluster.name
  virtual_network_name = azurerm_virtual_network.cluster.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "control_plane" {
  name                = "${var.name_prefix}-control-plane-nsg"
  location            = azurerm_resource_group.cluster.location
  resource_group_name = azurerm_resource_group.cluster.name
  tags                = local.common_tags

  security_rule {
    name                       = "AllowAdminSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAdminKubernetesAPI"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowClusterInternal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.vnet_cidr
    destination_address_prefix = var.vnet_cidr
  }
}

resource "azurerm_network_security_group" "gpu_worker" {
  name                = "${var.name_prefix}-gpu-worker-nsg"
  location            = azurerm_resource_group.cluster.location
  resource_group_name = azurerm_resource_group.cluster.name
  tags                = local.common_tags

  security_rule {
    name                       = "AllowAdminSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowPublicHTTP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowPublicHTTPS"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowClusterInternal"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.vnet_cidr
    destination_address_prefix = var.vnet_cidr
  }
}

resource "azurerm_public_ip" "control_plane" {
  name                = "${var.name_prefix}-control-plane-pip"
  location            = azurerm_resource_group.cluster.location
  resource_group_name = azurerm_resource_group.cluster.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_public_ip" "gpu_worker" {
  name                = "${var.name_prefix}-gpu-worker-pip"
  location            = azurerm_resource_group.cluster.location
  resource_group_name = azurerm_resource_group.cluster.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.name_prefix}-${substr(md5(azurerm_resource_group.cluster.id), 0, 8)}"
  tags                = local.common_tags
}

resource "azurerm_network_interface" "control_plane" {
  name                  = "${var.name_prefix}-control-plane-nic"
  location              = azurerm_resource_group.cluster.location
  resource_group_name   = azurerm_resource_group.cluster.name
  ip_forwarding_enabled = true
  tags                  = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.nodes.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.control_plane_private_ip
    public_ip_address_id          = azurerm_public_ip.control_plane.id
  }
}

resource "azurerm_network_interface" "gpu_worker" {
  name                  = "${var.name_prefix}-gpu-worker-nic"
  location              = azurerm_resource_group.cluster.location
  resource_group_name   = azurerm_resource_group.cluster.name
  ip_forwarding_enabled = true
  tags                  = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.nodes.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.gpu_worker_private_ip
    public_ip_address_id          = azurerm_public_ip.gpu_worker.id
  }
}

resource "azurerm_network_interface_security_group_association" "control_plane" {
  network_interface_id      = azurerm_network_interface.control_plane.id
  network_security_group_id = azurerm_network_security_group.control_plane.id
}

resource "azurerm_network_interface_security_group_association" "gpu_worker" {
  network_interface_id      = azurerm_network_interface.gpu_worker.id
  network_security_group_id = azurerm_network_security_group.gpu_worker.id
}
