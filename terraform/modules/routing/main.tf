# azurerm 5.x: bgp_route_propagation_enabled replaces disable_bgp_route_propagation, inverted.
resource "azurerm_route_table" "spoke" {
  name                          = "rt-spoke-workloads"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  bgp_route_propagation_enabled = false

  route {
    name                   = "to-onprem-via-firewall"
    address_prefix         = var.onprem_range
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }

  route {
    name                   = "to-internet-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }
}

# Return path. Without it the flow is asymmetric and the stateful firewall drops it.
# Propagation stays on here; the gateway needs its own routes.
resource "azurerm_route_table" "hub_gateway" {
  name                = "rt-hub-gateway"
  location            = var.location
  resource_group_name = var.resource_group_name

  route {
    name                   = "to-spoke-via-firewall"
    address_prefix         = var.spoke_range
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "spoke" {
  subnet_id      = var.spoke_subnet_id
  route_table_id = azurerm_route_table.spoke.id
}

resource "azurerm_subnet_route_table_association" "hub_gateway" {
  subnet_id      = var.hub_gateway_subnet_id
  route_table_id = azurerm_route_table.hub_gateway.id
}