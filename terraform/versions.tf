terraform {
  required_version = ">= 1.15.0, < 1.17.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.7.0"
    }
  }
}

provider "azurerm" {
  features {}
}
