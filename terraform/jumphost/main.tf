terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-store-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "jumphost.tfstate"
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

# No public IP allowed and no default outbound: without NAT the agent is offline.
resource "azurerm_public_ip" "nat" {
  name                = "pip-store-nat"
  resource_group_name = local.rg_name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "main" {
  name                = "natgw-store"
  resource_group_name = local.rg_name
  location            = local.location
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "pe" {
  subnet_id      = data.terraform_remote_state.network.outputs.pe_subnet_id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# Generated at apply time so no key is ever typed or committed
resource "tls_private_key" "jumphost" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_network_interface" "jumphost" {
  name                = "nic-store-jumphost"
  resource_group_name = local.rg_name
  location            = local.location
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.terraform_remote_state.network.outputs.pe_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jumphost" {
  name                              = "vm-store-jumphost"
  resource_group_name               = local.rg_name
  location                          = local.location
  size                              = "Standard_B2s_v2"
  admin_username                    = "azureuser"
  network_interface_ids             = [azurerm_network_interface.jumphost.id]
  vm_agent_platform_updates_enabled = true
  tags                              = local.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.jumphost.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_key_vault_secret" "jumphost_ssh_key" {
  name         = "jumphost-ssh-private-key"
  value        = tls_private_key.jumphost.private_key_pem
  key_vault_id = data.terraform_remote_state.platform.outputs.key_vault_id
}
