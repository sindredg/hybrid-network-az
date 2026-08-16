# If we want Terraform to manage the resource group:
resource "azurerm_resource_group" "rg" {
  name     = local.resource_group_name
  location = local.location
}

# Create all VNets using the map loop
resource "azurerm_virtual_network" "vnet" {
  for_each            = local.networks
  name                = each.value.name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = each.value.address_space
}

# Create all subnets using the flattened loop
resource "azurerm_subnet" "subnet" {
  for_each             = { for s in local.all_subnets : s.key => s }
  name                 = each.value.subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet[each.value.vnet_key].name
  address_prefixes     = [each.value.address_prefix]
}

# Hub to Spoke Peering
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "peer-hub-to-spoke"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_network_name         = azurerm_virtual_network.vnet["hub"].name
  remote_virtual_network_id    = azurerm_virtual_network.vnet["spoke"].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "peer-spoke-to-hub"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_network_name         = azurerm_virtual_network.vnet["spoke"].name
  remote_virtual_network_id    = azurerm_virtual_network.vnet["hub"].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = true
  depends_on                   = [azurerm_virtual_network_gateway.hub_gw]
}

# Public IPs for VPN Gateways
resource "azurerm_public_ip" "vpn_pip" {
  for_each            = { onprem = "onprem", hub = "hub" }
  name                = "pip-vpn-${each.key}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

# On-Prem VPN Gateway
resource "azurerm_virtual_network_gateway" "onprem_gw" {
  name                = "vgw-onprem"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw1"

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn_pip["onprem"].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.subnet["onprem-GatewaySubnet"].id
  }
}

# Hub VPN Gateway
resource "azurerm_virtual_network_gateway" "hub_gw" {
  name                = "vgw-hub"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw1"

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn_pip["hub"].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.subnet["hub-GatewaySubnet"].id
  }
}

# Site-to-Site Connections
resource "azurerm_virtual_network_gateway_connection" "onprem_to_hub" {
  name                            = "conn-onprem-to-hub"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  type                            = "Vnet2Vnet"
  virtual_network_gateway_id      = azurerm_virtual_network_gateway.onprem_gw.id
  peer_virtual_network_gateway_id = azurerm_virtual_network_gateway.hub_gw.id
  shared_key                      = var.vpn_shared_key
}

resource "azurerm_virtual_network_gateway_connection" "hub_to_onprem" {
  name                            = "conn-hub-to-onprem"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  type                            = "Vnet2Vnet"
  virtual_network_gateway_id      = azurerm_virtual_network_gateway.hub_gw.id
  peer_virtual_network_gateway_id = azurerm_virtual_network_gateway.onprem_gw.id
  shared_key                      = var.vpn_shared_key
}