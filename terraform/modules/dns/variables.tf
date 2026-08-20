variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "hub_vnet_id" { type = string }
variable "inbound_subnet_id" { type = string }
variable "outbound_subnet_id" { type = string }
variable "inbound_ip" { type = string }

# Must end with a trailing dot.
variable "onprem_zone" { type = string }

variable "onprem_dns_server" { type = string }
variable "linked_vnet_ids" { type = map(string) }