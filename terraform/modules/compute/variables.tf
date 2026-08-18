variable "resource_group_name" { type = string }
variable "location" { type = string }

# From modules/network, keyed <network>-<subnet name>.
variable "subnet_ids" { type = map(string) }

# One entry per VM, carrying its subnet key and pinned private address.
variable "workload_vms" { type = any }

# Bastion sits in the on-prem region, not with the hub.
variable "bastion_location" { type = string }

variable "vm_size" { type = string }
variable "admin_username" { type = string }
variable "admin_ssh_key" { type = string }
