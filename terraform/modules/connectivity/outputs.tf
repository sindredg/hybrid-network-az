output "gateway_ids" { value = { for network_key, gateway in azurerm_virtual_network_gateway.gw : network_key => gateway.id } }

# The tunnel endpoints.
output "public_ips" { value = { for network_key, public_ip in azurerm_public_ip.vpn : network_key => public_ip.ip_address } }

# For querying tunnel status with the CLI.
output "connection_names" { value = [for connection in azurerm_virtual_network_gateway_connection.this : connection.name] }
