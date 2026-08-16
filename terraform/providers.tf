terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
  }
}

# Authenticates via OpenID Connect (OIDC) in GitHub Actions
provider "azurerm" {
  features {}
  use_oidc = true
}