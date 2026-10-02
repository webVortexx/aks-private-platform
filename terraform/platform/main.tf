terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-store-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "platform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-store-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "network.tfstate"
  }
}

locals {
  rg_name  = data.terraform_remote_state.network.outputs.resource_group_name
  location = data.terraform_remote_state.network.outputs.location

  tags = {
    "Business Unit" = "Engineering"
    "Cost Center"   = "CC-1001"
  }
}

# Globally unique names; ACR allows no hyphens.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "azurerm_container_registry" "main" {
  name                = "acrstore${random_string.suffix.result}"
  resource_group_name = local.rg_name
  location            = local.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

# RBAC mode: creating the vault grants no data access.
resource "azurerm_key_vault" "main" {
  name                       = "kv-store-${random_string.suffix.result}"
  resource_group_name        = local.rg_name
  location                   = local.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = local.tags
}

resource "azurerm_role_assignment" "acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Gives the vault a private IP here; the zone group writes the A record.
resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-store-keyvault"
  location            = local.location
  resource_group_name = local.rg_name
  subnet_id           = data.terraform_remote_state.network.outputs.pe_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-keyvault"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "keyvault-dns-zone-group"
    private_dns_zone_ids = [data.terraform_remote_state.network.outputs.keyvault_dns_zone_id]
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-store"
  location            = local.location
  resource_group_name = local.rg_name
  dns_prefix          = "aks-store"
  sku_tier            = "Free"

  private_cluster_enabled = true
  private_dns_zone_id     = "System"
  oidc_issuer_enabled     = true

  default_node_pool {
    name           = "system"
    node_count     = 2
    vm_size        = "Standard_D2s_v5"
    vnet_subnet_id = data.terraform_remote_state.network.outputs.aks_subnet_id
    tags           = local.tags

    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # calico: without a policy engine, NetworkPolicy is silently ignored.
  network_profile {
    network_plugin = "kubenet"
    network_policy = "calico"
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }

  tags = local.tags
}

# Pulls use the kubelet identity, not the cluster identity.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
