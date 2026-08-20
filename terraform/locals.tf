locals {
  location            = var.location
  resource_group_name = var.resource_group_name

  networks = {
    onprem = {
      name          = "vnet-onprem"
      location      = "denmarkeast" # <-- Moved to Denmark East
      address_space = ["192.168.0.0/16"]
      has_gateway   = true
      dns_servers   = var.deploy_dns ? ["10.0.3.4"] : []
      subnets = {
        GatewaySubnet         = { prefix = "192.168.0.0/24" }
        snet-onprem-workloads = { prefix = "192.168.1.0/24" }
        AzureBastionSubnet    = { prefix = "192.168.2.0/26" } # admin bastion, on-prem only, /26 min
      }
    }

    hub = {
      name          = "vnet-hub"
      location      = "swedencentral" # Stays in Sweden Central
      address_space = ["10.0.0.0/16"]
      has_gateway   = true
      subnets = {
        GatewaySubnet       = { prefix = "10.0.0.0/24" }
        AzureFirewallSubnet = { prefix = "10.0.1.0/24" }
        snet-dns-inbound    = { prefix = "10.0.3.0/28", delegation = "Microsoft.Network/dnsResolvers" }
        snet-dns-outbound   = { prefix = "10.0.3.16/28", delegation = "Microsoft.Network/dnsResolvers" }
      }
    }

    spoke = {
      name          = "vnet-spoke"
      location      = "swedencentral" # Stays in Sweden Central
      address_space = ["10.1.0.0/16"]
      has_gateway   = false
      subnets = {
        snet-spoke-workloads = { prefix = "10.1.0.0/24" }
        snet-privatelink     = { prefix = "10.1.1.0/24" }
      }
    }
  }

  # Reserved: AzureFirewallManagementSubnet 10.0.4.0/26, only for the Basic firewall SKU.

  # The spoke has no gateway. Looping over all networks is what created pip-vpn-spoke.
  gateway_networks = { for k, v in local.networks : k => v if v.has_gateway }

  # One entry per direction. Peering is not symmetric: each side declares its own flags.
  peerings = [
    { name = "peer-hub-to-spoke", from = "hub", to = "spoke", allow_gateway_transit = true, use_remote_gateways = false },
    { name = "peer-spoke-to-hub", from = "spoke", to = "hub", allow_gateway_transit = false, use_remote_gateways = true },
  ]

  # Also one per direction. A VNet-to-VNet tunnel is two connections pointing at each other.
  connections = [
    { name = "conn-onprem-to-hub", from = "onprem", to = "hub" },
    { name = "conn-hub-to-onprem", from = "hub", to = "onprem" },
  ]

  # Compute is opt-in. An empty map means the VM loops produce nothing.
  workload_vms = var.deploy_workloads ? {
    onprem = {
      name       = "vm-onprem"
      subnet_key = "onprem-snet-onprem-workloads"
      private_ip = "192.168.1.4"
      location   = "denmarkeast" # Matches the Denmark East on-prem VNet
    }
    spoke = {
      name       = "vm-spoke"
      subnet_key = "spoke-snet-spoke-workloads"
      private_ip = "10.1.0.4"
      location   = "swedencentral" # Matches the Sweden Central spoke VNet
    }
  } : {}

  # NSGs are free, so they exist whether or not the VMs do.
  # The deny-all rule overrides the default AllowVnetInBound, which otherwise
  # permits everything from peered VNets and across the tunnel.
  network_security_groups = {
    onprem-workloads = {
      subnet_key = "onprem-snet-onprem-workloads"
      rules = [
        { name = "allow-ssh-from-spoke", priority = 100, protocol = "Tcp", port = "22", source = "10.1.0.0/24" },
        { name = "allow-icmp-from-spoke", priority = 110, protocol = "Icmp", port = "*", source = "10.1.0.0/24" },
        { name = "allow-ssh-from-bastion", priority = 120, protocol = "Tcp", port = "22", source = "192.168.2.0/26" },
        { name = "allow-dns-from-resolver", priority = 130, protocol = "Udp", port = "53", source = "10.0.3.16/28" },
        { name = "deny-all-inbound", priority = 4096, protocol = "*", port = "*", source = "*", access = "Deny" },
      ]
    }
    spoke-workloads = {
      subnet_key = "spoke-snet-spoke-workloads"
      rules = [
        # Admin reaches the spoke by hopping from the on-prem workload across the tunnel; no bastion in this region.
        { name = "allow-ssh-from-onprem", priority = 100, protocol = "Tcp", port = "22", source = "192.168.1.0/24" },
        { name = "allow-icmp-from-onprem", priority = 110, protocol = "Icmp", port = "*", source = "192.168.1.0/24" },
        { name = "deny-all-inbound", priority = 4096, protocol = "*", port = "*", source = "*", access = "Deny" },
      ]
    }
  }
}
