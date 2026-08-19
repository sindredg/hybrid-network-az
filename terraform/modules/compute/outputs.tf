# The addresses the cross-tunnel tests target.
output "vm_private_ips" { value = { for k, v in azurerm_linux_virtual_machine.vm : k => v.private_ip_address } }

output "bastion_public_ip" { value = azurerm_public_ip.bastion.ip_address }

# Granted Key Vault Secrets User out of band; Terraform has no role-assignment rights.
output "spoke_vm_principal_id" {
  value = try(azurerm_linux_virtual_machine.vm["spoke"].identity[0].principal_id, null)
}