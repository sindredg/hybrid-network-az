terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
        random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Authenticates via OpenID Connect (OIDC) in GitHub Actions
provider "azurerm" {
  features {}
  use_oidc = true
}