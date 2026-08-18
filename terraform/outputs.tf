output "resource_group_name" { value = azurerm_resource_group.rg.name }

# The deployed address plan, for comparing against the docs.
output "subnet_prefixes" { value = module.network.subnet_prefixes }

output "subnet_ids" { value = module.network.subnet_ids }

# Tunnel endpoints, one per gateway.
output "gateway_public_ips" { value = module.connectivity.public_ips }

# Empty when deploy_workloads is false and the compute module is not instantiated.
output "vm_private_ips" { value = try(module.compute[0].vm_private_ips, {}) }
