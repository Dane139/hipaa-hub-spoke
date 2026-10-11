variable "yourname" {
  description = "Your name suffix for all resource names. Lowercase, no spaces."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project     = "hipaa-hub-spoke"
    environment = "lab"
    managed_by  = "terraform"
    compliance  = "hipaa"
  }
}

# Hub address space
variable "hub_address_space" {
  type    = string
  default = "10.0.0.0/16"
}

variable "hub_firewall_subnet" {
  type    = string
  default = "10.0.1.0/26"
}

variable "hub_bastion_subnet" {
  type    = string
  default = "10.0.2.0/27"
}

variable "hub_gateway_subnet" {
  type    = string
  default = "10.0.3.0/27"
}

variable "hub_shared_subnet" {
  type    = string
  default = "10.0.4.0/24"
}

# Spoke 1 address space — clinical ePHI
variable "spoke1_address_space" {
  type    = string
  default = "10.1.0.0/16"
}

variable "spoke1_app_subnet" {
  type    = string
  default = "10.1.1.0/24"
}

variable "spoke1_data_subnet" {
  type    = string
  default = "10.1.2.0/24"
}

# Spoke 2 address space — analytics
variable "spoke2_address_space" {
  type    = string
  default = "10.2.0.0/16"
}

variable "spoke2_app_subnet" {
  type    = string
  default = "10.2.1.0/24"
}

variable "spoke2_data_subnet" {
  type    = string
  default = "10.2.2.0/24"
}