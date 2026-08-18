# Workload VMs and the Bastion host that reaches them.

resource "azurerm_network_interface" "vm" {
  for_each            = var.workload_vms
  name                = "nic-${each.value.name}"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_ids[each.value.subnet_key]
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each                        = var.workload_vms
  name                            = each.value.name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  network_interface_ids           = [azurerm_network_interface.vm[each.key].id]
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-hub"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Standard for ip_connect (reach vnet-onprem over the tunnel) and tunneling (native client).
resource "azurerm_bastion_host" "hub" {
  name                = "bastion-hub"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  ip_connect_enabled  = true
  tunneling_enabled   = true

  ip_configuration {
    name                 = "configuration"
    subnet_id            = var.subnet_ids["hub-AzureBastionSubnet"]
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}