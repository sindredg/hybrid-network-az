# A resolver references exactly one VNet and must be in the same region.
resource "azurerm_private_dns_resolver" "hub" {
  name                = "dnspr-hub"
  resource_group_name = var.resource_group_name
  location            = var.location
  virtual_network_id  = var.hub_vnet_id
}

# On-prem points here to resolve Azure private names.
resource "azurerm_private_dns_resolver_inbound_endpoint" "hub" {
  name                    = "inbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  location                = var.location

  ip_configurations {
    private_ip_allocation_method = "Static"
    private_ip_address           = var.inbound_ip
    subnet_id                    = var.inbound_subnet_id
  }
}

# Azure forwards out of here to reach on-prem names.
resource "azurerm_private_dns_resolver_outbound_endpoint" "hub" {
  name                    = "outbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  location                = var.location
  subnet_id               = var.outbound_subnet_id
}

resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "hub" {
  name                                       = "ruleset-hub"
  resource_group_name                        = var.resource_group_name
  location                                   = var.location
  private_dns_resolver_outbound_endpoint_ids = [azurerm_private_dns_resolver_outbound_endpoint.hub.id]
}

resource "azurerm_private_dns_resolver_forwarding_rule" "onprem" {
  name                      = "to-onprem"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.hub.id
  domain_name               = var.onprem_zone
  enabled                   = true

  target_dns_servers {
    ip_address = var.onprem_dns_server
    port       = 53
  }
}

resource "azurerm_private_dns_resolver_virtual_network_link" "this" {
  for_each                  = var.linked_vnet_ids
  name                      = "link-${each.key}"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.hub.id
  virtual_network_id        = each.value
}