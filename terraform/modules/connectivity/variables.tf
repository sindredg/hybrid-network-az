variable "resource_group_name" { type = string }
variable "location" { type = string }

# Only networks that terminate a tunnel; the spoke borrows the hub's gateway.
variable "gateway_networks" { type = any }

# From modules/network, keyed <network>-<subnet name>.
variable "subnet_ids" { type = map(string) }

# One entry per direction: a VNet-to-VNet tunnel is two resources pointing at each other.
variable "connections" { type = any }

variable "vpn_shared_key" {
  type      = string
  sensitive = true
}
