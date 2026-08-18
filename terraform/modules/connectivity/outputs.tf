output "gateway_ids" { value = { for k, v in azurerm_virtual_network_gateway.gw : k => v.id } }

# The tunnel endpoints.
output "public_ips" { value = { for k, v in azurerm_public_ip.vpn : k => v.ip_address } }

# For querying tunnel status with the CLI.
output "connection_names" { value = [for c in azurerm_virtual_network_gateway_connection.this : c.name] }
