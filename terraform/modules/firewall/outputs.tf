output "private_ip" { value = azurerm_firewall.hub.ip_configuration[0].private_ip_address }
output "public_ip" { value = azurerm_public_ip.fw.ip_address }
output "workspace_id" { value = azurerm_log_analytics_workspace.hub.id }