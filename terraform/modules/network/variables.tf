variable "resource_group_name" { type = string }
variable "location" { type = string }

# The whole topology as data. See the root locals.tf.
variable "networks" { type = any }

# Subnet-bound rule sets, keyed by NSG name suffix.
variable "network_security_groups" { type = any }
