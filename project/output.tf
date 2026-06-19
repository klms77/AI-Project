output "vm_app_private_ip" {
  value = azurerm_network_interface.app.private_ip_address
}

output "vm_app_public_ip" {
  value = azurerm_public_ip.app.ip_address
}

output "vm_db_private_ip" {
  value = azurerm_network_interface.db.private_ip_address
}

output "vm_db_public_ip" {
  value = azurerm_public_ip.db.ip_address
}

output "resource_group" {
  value = azurerm_resource_group.lab.name
}
