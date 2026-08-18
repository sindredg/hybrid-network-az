resource "azurerm_public_ip" "fw" {
  name                = "pip-firewall-hub"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_firewall_policy" "hub" {
  name                = "fwp-hub"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard" # Basic needs a second subnet and has no DNS proxy
}

# Denies by default. Without these the phase 2 ping stops working rather than being inspected.
resource "azurerm_firewall_policy_rule_collection_group" "lab" {
  name               = "rcg-lab"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  priority           = 500

  network_rule_collection {
    name     = "cross-premises"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "icmp"
      protocols             = ["ICMP"]
      source_addresses      = [var.spoke_range, var.onprem_range]
      destination_addresses = [var.spoke_range, var.onprem_range]
      destination_ports     = ["*"]
    }

    rule {
      name                  = "ssh"
      protocols             = ["TCP"]
      source_addresses      = [var.spoke_range, var.onprem_range]
      destination_addresses = [var.spoke_range, var.onprem_range]
      destination_ports     = ["22"]
    }
  }

  # Permissive so apt and curl work. Narrow it later to demonstrate a deny.
  application_rule_collection {
    name     = "spoke-egress"
    priority = 200
    action   = "Allow"

    rule {
      name              = "web"
      source_addresses  = [var.spoke_range]
      destination_fqdns = ["*"]
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
    }
  }
}

resource "azurerm_firewall" "hub" {
  name                = "fw-hub"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.hub.id
  zones               = ["1", "2", "3"]

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = var.firewall_subnet_id
    public_ip_address_id = azurerm_public_ip.fw.id
  }
}

resource "azurerm_log_analytics_workspace" "hub" {
  name                = "law-hybrid-network"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_monitor_diagnostic_setting" "fw" {
  name                       = "fw-to-law"
  target_resource_id         = azurerm_firewall.hub.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  enabled_log { category = "AZFWNetworkRule" }
  enabled_log { category = "AZFWApplicationRule" }
}