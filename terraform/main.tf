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
  gateway_networks    = local.gateway_networks
  subnet_ids          = module.network.subnet_ids
  connections         = local.connections
  vpn_shared_key      = var.vpn_shared_key
}

module "compute" {
  count               = var.deploy_workloads ? 1 : 0
  source              = "./modules/compute"
  resource_group_name = azurerm_resource_group.rg.name
  subnet_ids          = module.network.subnet_ids
  workload_vms        = local.workload_vms
  bastion_location    = local.networks.onprem.location
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  admin_ssh_key       = var.admin_ssh_public_key

  # vnet-onprem resolves DNS through the tunnel, so the VM should not boot before the gateways finish.
  depends_on = [module.connectivity]
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

# Stays at root: it wires two modules together, and use_remote_gateways fails before the hub gateway exists.
resource "azurerm_virtual_network_peering" "this" {
  for_each = { for peering in local.peerings : peering.name => peering }

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
    hub   = module.network.vnet_ids["hub"]
    spoke = module.network.vnet_ids["spoke"]
  }
  tenant_id = data.azurerm_client_config.current.tenant_id
}

# The identity comes from compute and the vault from privatelink, so the assignment lives at the root.
resource "azurerm_role_assignment" "spoke_key_vault_secrets_user" {
  for_each = var.deploy_privatelink && var.deploy_workloads ? {
    spoke = module.compute[0].vm_principal_ids["spoke"]
  } : {}

  scope              = module.privatelink[0].vault_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
  principal_id       = each.value
  principal_type     = "ServicePrincipal"

  # A new system-assigned identity can lag in Entra ID; the object ID already comes from Azure.
  skip_service_principal_aad_check = true
}

module "dns" {
  count               = var.deploy_dns ? 1 : 0
  source              = "./modules/dns"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.networks.hub.location
  hub_vnet_id         = module.network.vnet_ids["hub"]
  inbound_subnet_id   = module.network.subnet_ids["hub-snet-dns-inbound"]
  outbound_subnet_id  = module.network.subnet_ids["hub-snet-dns-outbound"]
  inbound_ip          = local.dns_config.resolver_inbound_ip
  onprem_zone         = local.dns_config.onprem_zone
  onprem_dns_server   = local.dns_config.onprem_dns_server
  linked_vnet_ids     = { hub = module.network.vnet_ids["hub"], spoke = module.network.vnet_ids["spoke"] }
}