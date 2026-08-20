output "resolver_name" {
  value = azurerm_private_dns_resolver.hub.name
}

output "inbound_endpoint_ip" {
  value = azurerm_private_dns_resolver_inbound_endpoint.hub.ip_configurations[0].private_ip_address
}

output "outbound_endpoint_name" {
  value = azurerm_private_dns_resolver_outbound_endpoint.hub.name
}

output "forwarding_ruleset_name" {
  value = azurerm_private_dns_resolver_dns_forwarding_ruleset.hub.name
}
