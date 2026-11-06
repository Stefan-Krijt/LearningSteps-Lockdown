variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "learningsteps"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "vm_admin_username" {
  description = "Admin username for the VM"
  type        = string
  default     = "azureuser"
}

variable "vm_admin_ssh_key" {
  description = "SSH public key for VM access"
  type        = string
}

variable "db_admin_username" {
  description = "Administrator username for PostgreSQL"
  type        = string
  default     = "psqladmin"
}

variable "db_admin_password" {
  description = "Administrator password for PostgreSQL"
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "Name of the application database"
  type        = string
  default     = "learning_journal"
}

variable "my_ip" {
  description = "My current public IP for SSH access"
  type        = string
}