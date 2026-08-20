# Workload VMs and the Bastion host that reaches them.

resource "azurerm_network_interface" "vm" {
  for_each            = var.workload_vms
  name                = "nic-${each.value.name}"
  location            = each.value.location # Fixed: Uses per-VM location
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
  location                        = each.value.location # Fixed: Uses per-VM location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  network_interface_ids           = [azurerm_network_interface.vm[each.key].id]
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_key
  }

  # Only the spoke VM reads Key Vault, over the private endpoint.
  dynamic "identity" {
    for_each = each.key == "spoke" ? [1] : []

    content {
      type = "SystemAssigned"
    }
  }

  # dnsmasq gives the outbound forwarding rule something to target.
  custom_data = each.key == "onprem" ? base64encode(<<-EOF
    #cloud-config
    packages: [dnsmasq]
    write_files:
      - path: /etc/dnsmasq.d/lab.conf
        content: |
          listen-address=0.0.0.0
          bind-interfaces
          address=/app.corp.internal/192.168.1.4
    runcmd: [systemctl restart dnsmasq]
  EOF
  ) : null

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
  name                = "pip-bastion-onprem"
  location            = var.bastion_location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# The only bastion in the lab, and it sits on the on-prem side. Admins manage from
# the datacenter, reaching Azure workloads across the tunnel rather than directly.
resource "azurerm_bastion_host" "onprem" {
  name                = "bastion-onprem"
  location            = var.bastion_location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  ip_connect_enabled  = true # reach the spoke by IP over the tunnel
  tunneling_enabled   = true # native client, so sessions run from a local terminal

  ip_configuration {
    name                 = "configuration"
    subnet_id            = var.subnet_ids["onprem-AzureBastionSubnet"]
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}