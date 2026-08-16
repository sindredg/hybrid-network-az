locals {
  location            = var.location
  resource_group_name = var.resource_group_name

  # All our networks and their subnets in one clean spot
  networks = {
    onprem = {
      name          = "vnet-onprem"
      address_space = ["192.168.0.0/16"]
      subnets = {
        GatewaySubnet         = "192.168.0.0/24"
        snet-onprem-workloads = "192.168.1.0/24"
      }
    }
    hub = {
      name          = "vnet-hub"
      address_space = ["10.0.0.0/16"]
      subnets = {
        GatewaySubnet       = "10.0.0.0/24"
        AzureFirewallSubnet = "10.0.1.0/24"
        AzureBastionSubnet  = "10.0.2.0/24"
      }
    }
    spoke = {
      name          = "vnet-spoke"
      address_space = ["10.1.0.0/16"]
      subnets = {
        snet-spoke-workloads = "10.1.0.0/24"
      }
    }
  }

  # Flattens the nested subnets so Terraform can loop through them easily
  all_subnets = flatten([
    for vnet_key, vnet_val in local.networks : [
      for subnet_name, address_prefix in vnet_val.subnets : {
        key            = "${vnet_key}-${subnet_name}"
        vnet_key       = vnet_key
        vnet_name      = vnet_val.name
        subnet_name    = subnet_name
        address_prefix = address_prefix
      }
    ]
  ])
}