output "vnet_ids" { value = { for network_key, vnet in azurerm_virtual_network.vnet : network_key => vnet.id } }
output "vnet_names" { value = { for network_key, vnet in azurerm_virtual_network.vnet : network_key => vnet.name } }

# Keyed <network>-<subnet name>. Every other module looks subnets up here.
output "subnet_ids" { value = { for subnet_key, subnet in azurerm_subnet.subnet : subnet_key => subnet.id } }

# The deployed address plan, for comparing against the docs.
output "subnet_prefixes" { value = { for subnet_key, subnet in azurerm_subnet.subnet : subnet_key => one(subnet.address_prefixes) } }
