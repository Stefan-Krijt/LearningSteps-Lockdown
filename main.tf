resource "azurerm_resource_group" "main" {
  name     = "rg-${var.prefix}"
  location = var.location
}
