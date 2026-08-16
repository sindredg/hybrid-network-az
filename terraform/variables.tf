variable "location" {
  type    = string
  default = "swedencentral"
}

variable "resource_group_name" {
  type    = string
  default = "rg-hybrid-network-lab"
}

variable "vpn_shared_key" {
  type      = string
  sensitive = true
}