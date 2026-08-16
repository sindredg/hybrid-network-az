locals {
  location            = var.location
  resource_group_name = var.resource_group_name

  # Topology as data. Adding a network or subnet is a data change, not a new resource block.
  # Subnet values are objects so one subnet can carry extra settings without the others caring.
  networks = {
    onprem = {
      name          = "vnet-onprem"
      address_space = ["192.168.0.0/16"]
      has_gateway   = true
      subnets = {
        GatewaySubnet         = { prefix = "192.168.0.0/24" }
        snet-onprem-workloads = { prefix = "192.168.1.0/24" }
      }
    }

    hub = {
      name          = "vnet-hub"
      address_space = ["10.0.0.0/16"]
      has_gateway   = true
      subnets = {
        GatewaySubnet       = { prefix = "10.0.0.0/24" }
        AzureFirewallSubnet = { prefix = "10.0.1.0/24" } # phase 3, /26 min
        AzureBastionSubnet  = { prefix = "10.0.2.0/24" } # phase 2, /26 min

        # phase 5, /28 min, delegated and otherwise empty
        snet-dns-inbound  = { prefix = "10.0.3.0/28", delegation = "Microsoft.Network/dnsResolvers" }
        snet-dns-outbound = { prefix = "10.0.3.16/28", delegation = "Microsoft.Network/dnsResolvers" }
      }
    }

    spoke = {
      name          = "vnet-spoke"
      address_space = ["10.1.0.0/16"]
      has_gateway   = false # borrows the hub gateway via peering transit
      subnets = {
        snet-spoke-workloads = { prefix = "10.1.0.0/24" }
        snet-privatelink     = { prefix = "10.1.1.0/24" } # phase 4
      }
    }
  }

  # Reserved: AzureFirewallManagementSubnet 10.0.4.0/26, only for the Basic firewall SKU.

  # for_each needs a flat collection. Each object carries vnet_key and a composite key,
  # because both vnet-onprem and vnet-hub contain a GatewaySubnet.
  all_subnets = flatten([
    for vnet_key, vnet_val in local.networks : [
      for subnet_name, subnet in vnet_val.subnets : {
        key            = "${vnet_key}-${subnet_name}"
        vnet_key       = vnet_key
        vnet_name      = vnet_val.name
        subnet_name    = subnet_name
        address_prefix = subnet.prefix
        delegation     = try(subnet.delegation, null)
      }
    ]
  ])

  # The spoke has no gateway. Looping over all networks is what created pip-vpn-spoke.
  gateway_networks = { for k, v in local.networks : k => v if v.has_gateway }
}