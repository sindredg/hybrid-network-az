# The addresses the cross-tunnel tests target.
output "vm_private_ips" { value = { for vm_key, vm in azurerm_linux_virtual_machine.vm : vm_key => vm.private_ip_address } }

output "bastion_public_ip" { value = azurerm_public_ip.bastion.ip_address }

# Only VMs with enable_identity = true appear in this map.
output "vm_principal_ids" {
  value = {
    for vm_key, vm in azurerm_linux_virtual_machine.vm :
    vm_key => vm.identity[0].principal_id
    if length(vm.identity) > 0
  }
}
