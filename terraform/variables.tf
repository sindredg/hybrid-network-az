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

variable "deploy_workloads" {
  description = "Deploy test VMs and Bastion. Off by default so compute is opt-in."
  type        = bool
  default     = false
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "Public key for VM access. Required when deploy_workloads is true."
  type        = string
  default     = ""
}

variable "vm_size" {
  description = "B2as_v2 has capacity in Sweden Central where B1s is restricted."
  type        = string
  default     = "Standard_B2as_v2"
}

variable "deploy_firewall" {
  description = "Firewall, routing and logging. The most expensive resource in the lab."
  type        = bool
  default     = false
}

variable "deploy_privatelink" {
  type    = bool
  default = false
}

variable "deploy_dns" {
  type    = bool
  default = false
}