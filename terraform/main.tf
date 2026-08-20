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
  bastion_location    = local.networks.onprem.location
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  admin_ssh_key       = var.admin_ssh_public_key
}

module "firewall" {
  count               = var.deploy_firewall ? 1 : 0
  source              = "./modules/firewall"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  firewall_subnet_id  = module.network.subnet_ids["hub-AzureFirewallSubnet"]
  spoke_range         = local.networks.spoke.address_space[0]
  onprem_range        = local.networks.onprem.address_space[0]
}

# Separate from the firewall module so the dependency is explicit and acyclic.
module "routing" {
  count                 = var.deploy_firewall ? 1 : 0
  source                = "./modules/routing"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  firewall_private_ip   = module.firewall[0].private_ip
  spoke_subnet_id       = module.network.subnet_ids["spoke-snet-spoke-workloads"]
  hub_gateway_subnet_id = module.network.subnet_ids["hub-GatewaySubnet"]
  spoke_range           = local.networks.spoke.address_space[0]
  onprem_range          = local.networks.onprem.address_space[0]
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

data "azurerm_client_config" "current" {}

module "privatelink" {
  count                      = var.deploy_privatelink ? 1 : 0
  source                     = "./modules/privatelink"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = local.networks.spoke.location
  private_endpoint_subnet_id = module.network.subnet_ids["spoke-snet-privatelink"]
  linked_vnet_ids = {
    hub    = module.network.vnet_ids["hub"]
    spoke  = module.network.vnet_ids["spoke"]
    onprem = module.network.vnet_ids["onprem"]
  }
  tenant_id = data.azurerm_client_config.current.tenant_id
}

module "dns" {
  count               = var.deploy_dns ? 1 : 0
  source              = "./modules/dns"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.networks.hub.location
  hub_vnet_id         = module.network.vnet_ids["hub"]
  inbound_subnet_id   = module.network.subnet_ids["hub-snet-dns-inbound"]
  outbound_subnet_id  = module.network.subnet_ids["hub-snet-dns-outbound"]
  inbound_ip          = "10.0.3.4"
  onprem_zone         = "corp.internal."
  onprem_dns_server   = "192.168.1.4"
  linked_vnet_ids     = { hub = module.network.vnet_ids["hub"], spoke = module.network.vnet_ids["spoke"] }
}