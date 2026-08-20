variable "resource_group_name" { type = string }

# From modules/network, keyed <network>-<subnet name>.
variable "subnet_ids" { type = map(string) }

# One entry per VM, carrying its subnet key and pinned private address.
variable "workload_vms" {
  type = map(object({
    name            = string
    subnet_key      = string
    private_ip      = string
    location        = string
    enable_identity = optional(bool, false)
    custom_data     = optional(string)
  }))
}

# Bastion sits in the on-prem region, not with the hub.
variable "bastion_location" { type = string }

variable "vm_size" { type = string }
variable "admin_username" { type = string }
variable "admin_ssh_key" { type = string }
