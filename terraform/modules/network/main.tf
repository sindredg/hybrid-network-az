# VNets, subnets and the NSGs bound to them.

locals {
  all_subnets = flatten([
    for network_key, network_config in var.networks : [
      for subnet_name, subnet_config in network_config.subnets : {
        key            = "${network_key}-${subnet_name}"
        vnet_key       = network_key
        subnet_name    = subnet_name
        address_prefix = subnet_config.prefix
        delegation     = subnet_config.delegation
      }
    ]
  ])

  # Each NSG names its VNet explicitly; no subnet-key string parsing is needed.
  nsg_locations = {
    for nsg_key, nsg_config in var.network_security_groups :
    nsg_key => coalesce(var.networks[nsg_config.vnet_key].location, var.location)
  }
}

resource "azurerm_virtual_network" "vnet" {
  for_each            = var.networks
  name                = each.value.name
  location            = coalesce(each.value.location, var.location)
  resource_group_name = var.resource_group_name
  address_space       = each.value.address_space
  dns_servers         = each.value.dns_servers
}

resource "azurerm_subnet" "subnet" {
  for_each             = { for subnet in local.all_subnets : subnet.key => subnet }
  name                 = each.value.subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet[each.value.vnet_key].name
  address_prefixes     = [each.value.address_prefix]

  # Only the DNS resolver subnets set this.
  dynamic "delegation" {
    for_each = each.value.delegation == null ? [] : [each.value.delegation]
    content {
      name = "delegation"
      service_delegation {
        name    = delegation.value
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

resource "azurerm_network_security_group" "nsg" {
  for_each            = var.network_security_groups
  name                = "nsg-${each.key}"
  location            = local.nsg_locations[each.key] # Matches the correct region automatically
  resource_group_name = var.resource_group_name

  dynamic "security_rule" {
    for_each = each.value.rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = security_rule.value.access
      protocol                   = security_rule.value.protocol
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefix      = security_rule.value.source
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg" {
  for_each                  = var.network_security_groups
  subnet_id                 = azurerm_subnet.subnet[each.value.subnet_key].id
  network_security_group_id = azurerm_network_security_group.nsg[each.key].id
}
