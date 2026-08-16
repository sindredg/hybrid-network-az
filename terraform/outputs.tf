output "resource_group_name" {
  description = "Resource group holding the lab."
  value       = azurerm_resource_group.rg.name
}

output "subnet_prefixes" {
  description = "Deployed address plan. Compare against README."
  value       = { for k, v in azurerm_subnet.subnet : k => one(v.address_prefixes) }
}

output "subnet_ids" {
  description = "Subnet IDs, keyed as <network>-<subnet name>."
  value       = { for k, v in azurerm_subnet.subnet : k => v.id }
}

output "gateway_public_ips" {
  description = "Tunnel endpoints, one per gateway."
  value       = { for k, v in azurerm_public_ip.vpn_pip : k => v.ip_address }
}

output "tunnel_status_command" {
  description = "Checks whether the tunnel is actually up."
  value       = "az network vpn-connection show -n ${azurerm_virtual_network_gateway_connection.onprem_to_hub.name} -g ${azurerm_resource_group.rg.name} --query connectionStatus -o tsv"
}