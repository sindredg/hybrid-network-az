# The addresses the cross-tunnel tests target.
output "vm_private_ips" { value = { for k, v in azurerm_linux_virtual_machine.vm : k => v.private_ip_address } }

output "bastion_public_ip" { value = azurerm_public_ip.bastion.ip_address }
