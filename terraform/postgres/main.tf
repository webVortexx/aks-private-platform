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
    key                  = "postgres.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-store-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "network.tfstate"
  }
}

data "terraform_remote_state" "platform" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-store-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "platform.tfstate"
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

# Generated at apply time; override_special avoids @ and / in connection strings.
resource "random_password" "pg" {
  length           = 24
  special          = true
  override_special = "!#$%*-_"
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                = "psql-store"
  resource_group_name = local.rg_name
  location            = local.location
  version             = "14"

  administrator_login    = "pgadminuser"
  administrator_password = random_password.pg.result

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768
  zone       = "1"

  # These three together select VNet-integrated mode: no public endpoint.
  public_network_access_enabled = false
  delegated_subnet_id           = data.terraform_remote_state.network.outputs.postgres_subnet_id
  private_dns_zone_id           = data.terraform_remote_state.network.outputs.postgres_dns_zone_id

  backup_retention_days = 7
  tags                  = local.tags
}

# The database the store applications use.
resource "azurerm_postgresql_flexible_server_database" "storedb" {
  name      = "storedb"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

resource "azurerm_key_vault_secret" "pg_password" {
  name         = "postgres-admin-password"
  value        = random_password.pg.result
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}

resource "azurerm_key_vault_secret" "pg_fqdn" {
  name         = "postgres-fqdn"
  value        = azurerm_postgresql_flexible_server.main.fqdn
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}

resource "azurerm_key_vault_secret" "pg_username" {
  name         = "postgres-admin-username"
  value        = azurerm_postgresql_flexible_server.main.administrator_login
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}
