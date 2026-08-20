variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "private_endpoint_subnet_id" { type = string }

# Zone must be linked to every VNet that needs to resolve the private name.
variable "linked_vnet_ids" { type = map(string) }

variable "tenant_id" { type = string }