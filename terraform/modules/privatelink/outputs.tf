output "vault_id" { value = azurerm_key_vault.lab.id }
output "vault_name" { value = azurerm_key_vault.lab.name }
output "vault_uri" { value = azurerm_key_vault.lab.vault_uri }
output "private_endpoint_ip" { value = azurerm_private_endpoint.kv.private_service_connection[0].private_ip_address }
