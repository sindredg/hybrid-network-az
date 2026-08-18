output "resource_group_name" { value = azurerm_resource_group.rg.name }

# The deployed address plan, for comparing against the docs.
output "subnet_prefixes" { value = module.network.subnet_prefixes }

output "subnet_ids" { value = module.network.subnet_ids }

# Tunnel endpoints, one per gateway.
output "gateway_public_ips" { value = module.connectivity.public_ips }

# Empty when deploy_workloads is false and the compute module is not instantiated.
output "vm_private_ips" { value = try(module.compute[0].vm_private_ips, {}) }

# Compare against show-next-hop after the route tables land.
output "firewall_private_ip" { value = try(module.firewall[0].private_ip, null) }

# The expected egress address from the spoke once routing is in place.
output "firewall_public_ip" { value = try(module.firewall[0].public_ip, null) }