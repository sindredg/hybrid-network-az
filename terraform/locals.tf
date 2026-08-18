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
    onprem = { name = "vm-onprem", subnet_key = "onprem-snet-onprem-workloads", private_ip = "192.168.1.4" }
    spoke  = { name = "vm-spoke", subnet_key = "spoke-snet-spoke-workloads", private_ip = "10.1.0.4" }
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
        { name = "allow-ssh-from-bastion", priority = 120, protocol = "Tcp", port = "22", source = "10.0.2.0/24" },
        { name = "deny-all-inbound", priority = 4096, protocol = "*", port = "*", source = "*", access = "Deny" },
      ]
    }
    spoke-workloads = {
      subnet_key = "spoke-snet-spoke-workloads"
      rules = [
        { name = "allow-ssh-from-bastion", priority = 100, protocol = "Tcp", port = "22", source = "10.0.2.0/24" },
        { name = "allow-ssh-from-onprem", priority = 110, protocol = "Tcp", port = "22", source = "192.168.0.0/24" },
        { name = "allow-icmp-from-onprem", priority = 120, protocol = "Icmp", port = "*", source = "192.168.0.0/24" },
        { name = "deny-all-inbound", priority = 4096, protocol = "*", port = "*", source = "*", access = "Deny" },
      ]
    }
  }
}
