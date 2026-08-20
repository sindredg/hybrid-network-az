# Key Vault names are globally unique.
resource "random_string" "kv" {
  length  = 6
  special = false
  upper   = false
}

# Public access off: reachable only through the private endpoint below.
resource "azurerm_key_vault" "lab" {
  name                          = "kv-hybrid-${random_string.kv.result}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

# Terraform writes this and never reads it back, so the vault can stay private.
resource "azurerm_key_vault_secret" "demo" {
  name         = "demo-secret"
  value        = "written-by-terraform-never-read-back"
  key_vault_id = azurerm_key_vault.lab.id
}

resource "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  for_each            = var.linked_vnet_ids
  name                = "link-${each.key}"
  private_dns_zone_id = azurerm_private_dns_zone.kv.id
  virtual_network_id  = each.value
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-keyvault"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-keyvault"
    private_connection_resource_id = azurerm_key_vault.lab.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  # Writes the A record into the zone automatically.
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
}