# Create the Key Vault
resource "azurerm_key_vault" "main" {
  name                        = "kv-lokiyn-ls"
  location                    = azurerm_resource_group.main.location
  resource_group_name         = azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  enable_rbac_authorization   = true
}

# Store the DB password
resource "azurerm_key_vault_secret" "db_password" {
  name         = "postgres-admin-password"
  value        = var.db_admin_password
  key_vault_id = azurerm_key_vault.main.id
}

# Grant the VM's identity permission to read the secret
resource "azurerm_role_assignment" "vm_keyvault_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.vm.identity[0].principal_id
}
