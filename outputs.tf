output "hub_vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "spoke1_vnet_id" {
  value = azurerm_virtual_network.spoke1.id
}

output "spoke2_vnet_id" {
  value = azurerm_virtual_network.spoke2.id
}

output "firewall_private_ip" {
  value       = azurerm_firewall.hub.ip_configuration[0].private_ip_address
  description = "Private IP of the Azure Firewall — UDRs in both spokes point here"
}

output "firewall_public_ip" {
  value = azurerm_public_ip.firewall.ip_address
}

output "bastion_name" {
  value = azurerm_bastion_host.hub.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.hub.vault_uri
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.hub.id
}

output "hub_resource_group" {
  value = azurerm_resource_group.hub.name
}

output "spoke1_resource_group" {
  value = azurerm_resource_group.spoke1.name
}

output "spoke2_resource_group" {
  value = azurerm_resource_group.spoke2.name
}
