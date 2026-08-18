resource "azurerm_resource_group" "rg" {
  name     = local.resource_group_name
  location = local.location
}

module "network" {
  source                  = "./modules/network"
  resource_group_name     = azurerm_resource_group.rg.name
  location                = azurerm_resource_group.rg.location
  networks                = local.networks
  network_security_groups = local.network_security_groups
}

module "connectivity" {
  source              = "./modules/connectivity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  gateway_networks    = local.gateway_networks
  subnet_ids          = module.network.subnet_ids
  connections         = local.connections
  vpn_shared_key      = var.vpn_shared_key
}

# Gated on the module block rather than on every resource inside it.
module "compute" {
  count               = var.deploy_workloads ? 1 : 0
  source              = "./modules/compute"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_ids          = module.network.subnet_ids
  workload_vms        = local.workload_vms
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  admin_ssh_key       = var.admin_ssh_public_key
}

# Stays at root: it wires two modules together, and the spoke side must wait for
# the hub gateway or Azure rejects use_remote_gateways.
resource "azurerm_virtual_network_peering" "this" {
  for_each = { for p in local.peerings : p.name => p }

  name                         = each.value.name
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_network_name         = module.network.vnet_names[each.value.from]
  remote_virtual_network_id    = module.network.vnet_ids[each.value.to]
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = each.value.allow_gateway_transit
  use_remote_gateways          = each.value.use_remote_gateways

  depends_on = [module.connectivity]
}
