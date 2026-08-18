output "vnet_ids" { value = { for k, v in azurerm_virtual_network.vnet : k => v.id } }
output "vnet_names" { value = { for k, v in azurerm_virtual_network.vnet : k => v.name } }

# Keyed <network>-<subnet name>. Every other module looks subnets up here.
output "subnet_ids" { value = { for k, v in azurerm_subnet.subnet : k => v.id } }

# The deployed address plan, for comparing against the docs.
output "subnet_prefixes" { value = { for k, v in azurerm_subnet.subnet : k => one(v.address_prefixes) } }
