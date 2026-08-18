# Public IPs, VPN gateways and the connections that form the tunnel.

resource "azurerm_public_ip" "vpn" {
  for_each            = var.gateway_networks
  name                = "pip-vpn-${each.key}"
  location            = each.value.location # per-network region, so onprem lands in Denmark East
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"] # required by the AZ gateway SKUs
}

resource "azurerm_virtual_network_gateway" "gw" {
  for_each            = var.gateway_networks
  name                = "vgw-${each.key}"
  location            = each.value.location # must match its GatewaySubnet's VNet
  resource_group_name = var.resource_group_name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw1AZ" # non-AZ SKUs are retired

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn[each.key].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = var.subnet_ids["${each.key}-GatewaySubnet"]
  }
}

resource "azurerm_virtual_network_gateway_connection" "this" {
  for_each = { for c in var.connections : c.name => c }

  name                            = each.value.name
  location                        = var.gateway_networks[each.value.from].location # follows its originating gateway
  resource_group_name             = var.resource_group_name
  type                            = "Vnet2Vnet"
  virtual_network_gateway_id      = azurerm_virtual_network_gateway.gw[each.value.from].id
  peer_virtual_network_gateway_id = azurerm_virtual_network_gateway.gw[each.value.to].id
  shared_key                      = var.vpn_shared_key
}