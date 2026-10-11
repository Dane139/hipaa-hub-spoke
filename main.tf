terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

data "azurerm_client_config" "current" {}

# ── Resource Groups ──────────────────────────────────────────────────
resource "azurerm_resource_group" "hub" {
  name     = "rg-hipaa-hub-${var.yourname}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "spoke1" {
  name     = "rg-hipaa-spoke1-${var.yourname}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "spoke2" {
  name     = "rg-hipaa-spoke2-${var.yourname}"
  location = var.location
  tags     = var.tags
}

# ── Log Analytics Workspace ───────────────────────────────────────────
# HIPAA requires audit logs be retained and protected.
# 90 days is the minimum recommended; production should be 365+.
resource "azurerm_log_analytics_workspace" "hub" {
  name                = "law-hipaa-${var.yourname}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
  tags                = var.tags
}

# ── Storage Account for audit log archive ────────────────────────────
resource "azurerm_storage_account" "audit" {
  name                       = "sthipaaaudit${var.yourname}"
  resource_group_name        = azurerm_resource_group.hub.name
  location                   = azurerm_resource_group.hub.location
  account_tier               = "Standard"
  account_replication_type   = "LRS"
  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true

  # Soft delete — prevents accidental or malicious deletion of audit logs
  blob_properties {
    delete_retention_policy {
      days = 90
    }
  }

  tags = var.tags
}

# ── Key Vault ─────────────────────────────────────────────────────────
resource "azurerm_key_vault" "hub" {
  name                       = "kv-hipaa-${var.yourname}"
  location                   = azurerm_resource_group.hub.location
  resource_group_name        = azurerm_resource_group.hub.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 90
  purge_protection_enabled   = true

  # Deny all public network access — HIPAA transmission security
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = var.tags
}

# Grant your account Key Vault Administrator
resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.hub.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ── Hub VNet ──────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub-${var.yourname}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = [var.hub_address_space]
  tags                = var.tags

  depends_on = [azurerm_network_watcher.main]
}

# AzureFirewallSubnet — name must be exactly this, minimum /26
resource "azurerm_subnet" "hub_firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_firewall_subnet]
}

# AzureBastionSubnet — name must be exactly this, minimum /27
resource "azurerm_subnet" "hub_bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_bastion_subnet]
}

resource "azurerm_subnet" "hub_gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_gateway_subnet]
}

resource "azurerm_subnet" "hub_shared" {
  name                 = "shared-services-subnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_shared_subnet]
}

# ── Azure Firewall ────────────────────────────────────────────────────
resource "azurerm_public_ip" "firewall" {
  name                = "pip-firewall-${var.yourname}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "hub" {
  name                = "fw-hipaa-${var.yourname}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.hub.id
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.hub_firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }
}

# Firewall diagnostic settings — ship all logs to Log Analytics
resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                       = "diag-firewall"
  target_resource_id         = azurerm_firewall.hub.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  enabled_log { category = "AzureFirewallApplicationRule" }
  enabled_log { category = "AzureFirewallNetworkRule" }
  enabled_log { category = "AzureFirewallDnsProxy" }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Firewall Policy — Application rules allowing HTTPS egress
resource "azurerm_firewall_policy" "hub" {
  name                = "fwpol-hipaa-${var.yourname}"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "main" {
  name               = "rcg-hipaa"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  priority           = 100

  # Allow HTTPS egress to Azure services only
  application_rule_collection {
    name     = "allow-azure-services"
    priority = 100
    action   = "Allow"

    rule {
      name              = "allow-azure-monitor"
      source_addresses  = ["10.1.0.0/16", "10.2.0.0/16"]
      destination_fqdns = ["*.ods.opinsights.azure.com", "*.oms.opinsights.azure.com", "*.monitoring.azure.com"]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name              = "allow-azure-updates"
      source_addresses  = ["10.1.0.0/16", "10.2.0.0/16"]
      destination_fqdns = ["*.windowsupdate.microsoft.com", "*.update.microsoft.com"]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  # Block all other internet traffic — deny by default
  network_rule_collection {
    name     = "deny-spoke-to-spoke"
    priority = 200
    action   = "Deny"

    rule {
      name                  = "deny-spoke1-to-spoke2"
      source_addresses      = ["10.1.0.0/16"]
      destination_addresses = ["10.2.0.0/16"]
      protocols             = ["Any"]
      destination_ports     = ["*"]
    }

    rule {
      name                  = "deny-spoke2-to-spoke1"
      source_addresses      = ["10.2.0.0/16"]
      destination_addresses = ["10.1.0.0/16"]
      protocols             = ["Any"]
      destination_ports     = ["*"]
    }
  }
}

# ── Azure Bastion ─────────────────────────────────────────────────────
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-${var.yourname}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "hub" {
  name                = "bastion-hipaa-${var.yourname}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "Standard"
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.hub_bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# ── Spoke 1 VNet ──────────────────────────────────────────────────────
resource "azurerm_virtual_network" "spoke1" {
  name                = "vnet-spoke1-${var.yourname}"
  location            = azurerm_resource_group.spoke1.location
  resource_group_name = azurerm_resource_group.spoke1.name
  address_space       = [var.spoke1_address_space]
  tags                = var.tags

  depends_on = [azurerm_network_watcher.main]
}

# NSG — Spoke 1 App Subnet
resource "azurerm_network_security_group" "spoke1_app" {
  name                = "nsg-spoke1-app-${var.yourname}"
  location            = azurerm_resource_group.spoke1.location
  resource_group_name = azurerm_resource_group.spoke1.name
  tags                = var.tags

  # Allow management from hub (Bastion)
  security_rule {
    name                       = "allow-hub-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = var.hub_address_space
    destination_address_prefix = "*"
  }

  # Deny all direct internet inbound
  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Deny cross-spoke traffic (belt-and-suspenders with firewall rule)
  security_rule {
    name                       = "deny-spoke2-inbound"
    priority                   = 3000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.spoke2_address_space
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet" "spoke1_app" {
  name                 = "app-subnet"
  resource_group_name  = azurerm_resource_group.spoke1.name
  virtual_network_name = azurerm_virtual_network.spoke1.name
  address_prefixes     = [var.spoke1_app_subnet]
}

resource "azurerm_subnet_network_security_group_association" "spoke1_app" {
  subnet_id                 = azurerm_subnet.spoke1_app.id
  network_security_group_id = azurerm_network_security_group.spoke1_app.id
}

resource "azurerm_network_security_group" "spoke1_data" {
  name                = "nsg-spoke1-data-${var.yourname}"
  location            = azurerm_resource_group.spoke1.location
  resource_group_name = azurerm_resource_group.spoke1.name
  tags                = var.tags

  # Only allow inbound from spoke1 app subnet — data tier isolation
  security_rule {
    name                       = "allow-spoke1-app-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["1433", "443"]
    source_address_prefix      = var.spoke1_app_subnet
    destination_address_prefix = "*"
  }

  # Deny everything else — ePHI data tier is maximally locked down
  security_rule {
    name                       = "deny-all-other-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet" "spoke1_data" {
  name                 = "data-subnet"
  resource_group_name  = azurerm_resource_group.spoke1.name
  virtual_network_name = azurerm_virtual_network.spoke1.name
  address_prefixes     = [var.spoke1_data_subnet]
}

resource "azurerm_subnet_network_security_group_association" "spoke1_data" {
  subnet_id                 = azurerm_subnet.spoke1_data.id
  network_security_group_id = azurerm_network_security_group.spoke1_data.id
}

# UDR — force all egress through Azure Firewall
resource "azurerm_route_table" "spoke1" {
  name                          = "rt-spoke1-${var.yourname}"
  location                      = azurerm_resource_group.spoke1.location
  resource_group_name           = azurerm_resource_group.spoke1.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "force-internet-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "spoke1_app" {
  subnet_id      = azurerm_subnet.spoke1_app.id
  route_table_id = azurerm_route_table.spoke1.id
}

resource "azurerm_subnet_route_table_association" "spoke1_data" {
  subnet_id      = azurerm_subnet.spoke1_data.id
  route_table_id = azurerm_route_table.spoke1.id
}

# ── Spoke 2 VNet ──────────────────────────────────────────────────────
resource "azurerm_virtual_network" "spoke2" {
  name                = "vnet-spoke2-${var.yourname}"
  location            = azurerm_resource_group.spoke2.location
  resource_group_name = azurerm_resource_group.spoke2.name
  address_space       = [var.spoke2_address_space]
  tags                = var.tags

  depends_on = [azurerm_network_watcher.main]
}

resource "azurerm_network_security_group" "spoke2_app" {
  name                = "nsg-spoke2-app-${var.yourname}"
  location            = azurerm_resource_group.spoke2.location
  resource_group_name = azurerm_resource_group.spoke2.name
  tags                = var.tags

  security_rule {
    name                       = "allow-hub-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = var.hub_address_space
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-spoke1-inbound"
    priority                   = 3000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.spoke1_address_space
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet" "spoke2_app" {
  name                 = "analytics-subnet"
  resource_group_name  = azurerm_resource_group.spoke2.name
  virtual_network_name = azurerm_virtual_network.spoke2.name
  address_prefixes     = [var.spoke2_app_subnet]
}

resource "azurerm_subnet_network_security_group_association" "spoke2_app" {
  subnet_id                 = azurerm_subnet.spoke2_app.id
  network_security_group_id = azurerm_network_security_group.spoke2_app.id
}

resource "azurerm_network_security_group" "spoke2_data" {
  name                = "nsg-spoke2-data-${var.yourname}"
  location            = azurerm_resource_group.spoke2.location
  resource_group_name = azurerm_resource_group.spoke2.name
  tags                = var.tags

  security_rule {
    name                       = "allow-spoke2-app-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["1433", "443"]
    source_address_prefix      = var.spoke2_app_subnet
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-all-other-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet" "spoke2_data" {
  name                 = "data-subnet"
  resource_group_name  = azurerm_resource_group.spoke2.name
  virtual_network_name = azurerm_virtual_network.spoke2.name
  address_prefixes     = [var.spoke2_data_subnet]
}

resource "azurerm_subnet_network_security_group_association" "spoke2_data" {
  subnet_id                 = azurerm_subnet.spoke2_data.id
  network_security_group_id = azurerm_network_security_group.spoke2_data.id
}

# UDR — Spoke 2
resource "azurerm_route_table" "spoke2" {
  name                          = "rt-spoke2-${var.yourname}"
  location                      = azurerm_resource_group.spoke2.location
  resource_group_name           = azurerm_resource_group.spoke2.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "force-internet-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "spoke2_app" {
  subnet_id      = azurerm_subnet.spoke2_app.id
  route_table_id = azurerm_route_table.spoke2.id
}

resource "azurerm_subnet_route_table_association" "spoke2_data" {
  subnet_id      = azurerm_subnet.spoke2_data.id
  route_table_id = azurerm_route_table.spoke2.id
}

# ── VNet Peering: Hub ↔ Spoke 1 ──────────────────────────────────────
resource "azurerm_virtual_network_peering" "hub_to_spoke1" {
  name                         = "peer-hub-to-spoke1"
  resource_group_name          = azurerm_resource_group.hub.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke1.id
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "spoke1_to_hub" {
  name                         = "peer-spoke1-to-hub"
  resource_group_name          = azurerm_resource_group.spoke1.name
  virtual_network_name         = azurerm_virtual_network.spoke1.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
  allow_virtual_network_access = true
}

# ── VNet Peering: Hub ↔ Spoke 2 ──────────────────────────────────────
resource "azurerm_virtual_network_peering" "hub_to_spoke2" {
  name                         = "peer-hub-to-spoke2"
  resource_group_name          = azurerm_resource_group.hub.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke2.id
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "spoke2_to_hub" {
  name                         = "peer-spoke2-to-hub"
  resource_group_name          = azurerm_resource_group.spoke2.name
  virtual_network_name         = azurerm_virtual_network.spoke2.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
  allow_virtual_network_access = true
}

# ── Defender for Cloud ────────────────────────────────────────────────
resource "azurerm_security_center_subscription_pricing" "defender_servers" {
  tier          = "Standard"
  resource_type = "VirtualMachines"
  subplan       = "P2"
}

resource "azurerm_security_center_subscription_pricing" "defender_storage" {
  tier          = "Standard"
  resource_type = "StorageAccounts"
  subplan       = "DefenderForStorageV2"
}

resource "azurerm_security_center_subscription_pricing" "defender_keyvault" {
  tier          = "Standard"
  resource_type = "KeyVaults"
  subplan       = "PerKeyVault"
}

# Assign the HIPAA built-in policy initiative to the subscription
resource "azurerm_subscription_policy_assignment" "hipaa" {
  name                 = "hipaa-hitech"
  display_name         = "HITRUST/HIPAA"
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/a169a624-5599-4385-a696-c8d643089fab"
  subscription_id      = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  location             = var.location

  identity {
    type = "SystemAssigned"
  }
}

# ── NSG Flow Logs ─────────────────────────────────────────────────────
# Requires Network Watcher in the same region
resource "azurerm_network_watcher" "main" {
  name                = "nw-hipaa-${var.yourname}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = var.tags
}

resource "azurerm_network_watcher_flow_log" "spoke1_app" {
  name                 = "flowlog-spoke1-app"
  network_watcher_name = azurerm_network_watcher.main.name
  resource_group_name  = azurerm_resource_group.hub.name
  target_resource_id   = azurerm_subnet.spoke1_app.id
  storage_account_id   = azurerm_storage_account.audit.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = 90
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.hub.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.hub.location
    workspace_resource_id = azurerm_log_analytics_workspace.hub.id
    interval_in_minutes   = 10
  }
}

resource "azurerm_network_watcher_flow_log" "spoke1_data" {
  name                 = "flowlog-spoke1-data"
  network_watcher_name = azurerm_network_watcher.main.name
  resource_group_name  = azurerm_resource_group.hub.name
  target_resource_id   = azurerm_subnet.spoke1_data.id
  storage_account_id   = azurerm_storage_account.audit.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = 90
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.hub.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.hub.location
    workspace_resource_id = azurerm_log_analytics_workspace.hub.id
    interval_in_minutes   = 10
  }
}

resource "azurerm_network_watcher_flow_log" "spoke2_app" {
  name                 = "flowlog-spoke2-app"
  network_watcher_name = azurerm_network_watcher.main.name
  resource_group_name  = azurerm_resource_group.hub.name
  target_resource_id   = azurerm_subnet.spoke2_app.id
  storage_account_id   = azurerm_storage_account.audit.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = 90
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.hub.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.hub.location
    workspace_resource_id = azurerm_log_analytics_workspace.hub.id
    interval_in_minutes   = 10
  }
}


resource "azurerm_network_watcher_flow_log" "spoke2_data" {
  name                 = "flowlog-spoke2-data"
  network_watcher_name = azurerm_network_watcher.main.name
  resource_group_name  = azurerm_resource_group.hub.name
  target_resource_id   = azurerm_subnet.spoke2_data.id
  storage_account_id   = azurerm_storage_account.audit.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = 90
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.hub.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.hub.location
    workspace_resource_id = azurerm_log_analytics_workspace.hub.id
    interval_in_minutes   = 10
  }
}