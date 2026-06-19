variable "participant_name" {
  description = "Your participant name (lowercase, no spaces)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "admin_password" {
  description = "Admin password for all VMs"
  type        = string
  sensitive   = true
}
