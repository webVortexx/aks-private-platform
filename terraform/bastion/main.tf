terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-store-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "bastion.tfstate"
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

locals {
  rg_name  = data.terraform_remote_state.network.outputs.resource_group_name
  location = data.terraform_remote_state.network.outputs.location

  tags = {
    "Business Unit" = "Engineering"
    "Cost Center"   = "CC-1001"
  }
}

# Standalone public IP, not on a NIC. Must be Standard + Static.
resource "azurerm_public_ip" "bastion" {
  name                = "pip-store-bastion"
  resource_group_name = local.rg_name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "main" {
  name                = "bastion-store"
  resource_group_name = local.rg_name
  location            = local.location
  sku                 = "Basic"
  tags                = local.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = data.terraform_remote_state.network.outputs.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  # Routinely exceeds Terraform's 30-minute default
  timeouts {
    create = "45m"
  }
}
