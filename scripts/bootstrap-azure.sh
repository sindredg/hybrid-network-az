#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Azure Bootstrap Script
# Sets up Least-Privilege Identity, OIDC Federated Trust, and Remote TF State
# -----------------------------------------------------------------------------

# Configuration Variables
GITHUB_ORG="sindredg"
GITHUB_REPO="hybrid-network-az"
LOCATION="swedencentral"
RG_STATE_NAME="rg-networks-tfstate"
STORAGE_ACCOUNT_NAME="sttfstatehybrid$(openssl rand -hex 3)" # Must be globally unique
CONTAINER_NAME="tfstate"
ROLE_NAME="HybridNetworkLabTFDeployer"

echo "--- 1. Validating Azure CLI Session ---"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Active Subscription: ${SUBSCRIPTION_ID}"
echo "Active Tenant:       ${TENANT_ID}"

echo "--- 2. Creating Custom Least-Privilege RBAC Role ---"
cat <<EOF > /tmp/custom-role.json
{
  "Name": "${ROLE_NAME}",
  "IsCustom": true,
  "Description": "Least-privilege role for deploying Hybrid Network Lab via Terraform",
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/*",
    "Microsoft.Network/*",
    "Microsoft.Compute/*",
    "Microsoft.Storage/*",
    "Microsoft.KeyVault/*"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/${SUBSCRIPTION_ID}"
  ]
}
EOF

if ! az role definition show --name "${ROLE_NAME}" &>/dev/null; then
  az role definition create --role-definition /tmp/custom-role.json
  echo "Custom role '${ROLE_NAME}' created."
else
  echo "Custom role '${ROLE_NAME}' already exists. Updating..."
  az role definition update --role-definition /tmp/custom-role.json
fi
rm -f /tmp/custom-role.json

echo "=== 3. Creating Service Principal & App Registration ==="
APP_NAME="sp-github-actions-hybrid-lab"
APP_ID=$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv)

if [ -z "${APP_ID}" ]; then
  APP_ID=$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)
  echo "Created App Registration with ID: ${APP_ID}"
fi

# Create Service Principal if not present
SP_ID=$(az ad sp list --display-name "${APP_NAME}" --query "[0].id" -o tsv)
if [ -z "${SP_ID}" ]; then
  SP_ID=$(az ad sp create --id "${APP_ID}" --query id -o tsv)
  echo "Created Service Principal with ID: ${SP_ID}"
fi

# Assign Custom Role
echo "Assigning '${ROLE_NAME}' role to Service Principal..."
az role assignment create \
  --assignee "${APP_ID}" \
  --role "${ROLE_NAME}" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}" \
  --output none || true

echo "--- 4. Configuring OIDC Federated Credentials for GitHub ---"
APP_OBJECT_ID=$(az ad app show --id "${APP_ID}" --query id -o tsv)

# Main Branch Credential
cat <<EOF > /tmp/fed-cred-main.json
{
  "name": "gh-actions-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main",
  "description": "GitHub Actions main branch execution",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF

az ad app federated-credential create --id "${APP_OBJECT_ID}" --parameters /tmp/fed-cred-main.json || true
rm -f /tmp/fed-cred-main.json

# Pull Request Credential
cat <<EOF > /tmp/fed-cred-pr.json
{
  "name": "gh-actions-pr",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_ORG}/${GITHUB_REPO}:pull_request",
  "description": "GitHub Actions pull request validation",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF

az ad app federated-credential create --id "${APP_OBJECT_ID}" --parameters /tmp/fed-cred-pr.json || true
rm -f /tmp/fed-cred-pr.json

echo "--- 5. Creating Azure Storage Account for Remote State ---"
az group create --name "${RG_STATE_NAME}" --location "${LOCATION}" --output none
az storage account create \
  --name "${STORAGE_ACCOUNT_NAME}" \
  --resource-group "${RG_STATE_NAME}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --output none

ACCOUNT_KEY=$(az storage account keys list --resource-group "${RG_STATE_NAME}" --account-name "${STORAGE_ACCOUNT_NAME}" --query '[0].value' -o tsv)

az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --account-key "${ACCOUNT_KEY}" \
  --output none

echo "-----------------------------------------------------------------------------"
echo " SETUP COMPLETE. Add the following secrets to GitHub Secrets:"
echo "-----------------------------------------------------------------------------"
echo "AZURE_CLIENT_ID:       ${APP_ID}"
echo "AZURE_TENANT_ID:       ${TENANT_ID}"
echo "AZURE_SUBSCRIPTION_ID: ${SUBSCRIPTION_ID}"
echo ""
echo "Remote State Configuration (Put in terraform/backend.tf):"
echo "  resource_group_name  = \"${RG_STATE_NAME}\""
echo "  storage_account_name = \"${STORAGE_ACCOUNT_NAME}\""
echo "  container_name       = \"${CONTAINER_NAME}\""
echo "  key                  = \"hybrid-lab.tfstate\""
echo "-----------------------------------------------------------------------------"