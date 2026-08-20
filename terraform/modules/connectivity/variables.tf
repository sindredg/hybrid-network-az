variable "resource_group_name" { type = string }

# Only networks that terminate a tunnel; the spoke borrows the hub's gateway.
variable "gateway_networks" {
  type = map(object({
    location = string
  }))
}

# From modules/network, keyed <network>-<subnet name>.
variable "subnet_ids" { type = map(string) }

# One entry per direction: a VNet-to-VNet tunnel is two resources pointing at each other.
variable "connections" {
  type = list(object({
    name = string
    from = string
    to   = string
  }))
}

variable "vpn_shared_key" {
  type      = string
  sensitive = true
}
