terraform {
  backend "azurerm" {
    # The actual variables (resource_group_name, storage_account_name, etc.) 
    # will be passed dynamically by GitHub Actions during 'terraform init'.
    use_oidc       = true
    container_name = "tfstate"
    key            = "hybrid-lab.tfstate"
  }
}