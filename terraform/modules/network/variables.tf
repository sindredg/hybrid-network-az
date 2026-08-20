variable "resource_group_name" { type = string }
variable "location" { type = string }

# The whole topology as data. See the root locals.tf.
variable "networks" {
  type = map(object({
    name          = string
    location      = optional(string)
    address_space = list(string)
    has_gateway   = bool
    dns_servers   = optional(list(string), [])
    subnets = map(object({
      prefix     = string
      delegation = optional(string)
    }))
  }))
}

# Subnet-bound rule sets, keyed by NSG name suffix.
variable "network_security_groups" {
  type = map(object({
    vnet_key   = string
    subnet_key = string
    rules = list(object({
      name     = string
      priority = number
      protocol = string
      port     = string
      source   = string
      access   = optional(string, "Allow")
    }))
  }))
}
