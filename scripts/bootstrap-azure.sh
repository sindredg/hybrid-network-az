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

add_fed_cred() {
  cat <<EOF > /tmp/fed-cred.json
{
  "name": "$1",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$2",
  "description": "$3",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
  if az ad app federated-credential create --id "${APP_OBJECT_ID}" \
       --parameters /tmp/fed-cred.json --output none 2>/dev/null; then
    echo "  added   $1 -> $2"
  else
    echo "  skipped $1 (already exists)"
  fi
  rm -f /tmp/fed-cred.json
}

# Name-based subjects, used by repos created before 2026-07-15.
add_fed_cred "gh-actions-main" \
  "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main" "main branch, name-based"
add_fed_cred "gh-actions-pr" \
  "repo:${GITHUB_ORG}/${GITHUB_REPO}:pull_request" "pull request, name-based"

# Immutable subjects embed numeric owner and repo IDs so a recycled name cannot inherit trust.
REPO_ID=""
OWNER_ID=""
if command -v gh >/dev/null 2>&1; then
  REPO_ID=$(gh api "repos/${GITHUB_ORG}/${GITHUB_REPO}" --jq '.id' 2>/dev/null || true)
  OWNER_ID=$(gh api "repos/${GITHUB_ORG}/${GITHUB_REPO}" --jq '.owner.id' 2>/dev/null || true)
fi

if [ -n "${REPO_ID}" ] && [ -n "${OWNER_ID}" ]; then
  IMMUTABLE="repo:${GITHUB_ORG}@${OWNER_ID}/${GITHUB_REPO}@${REPO_ID}"
  add_fed_cred "gh-actions-main-immutable" \
    "${IMMUTABLE}:ref:refs/heads/main" "main branch, immutable"
  add_fed_cred "gh-actions-pr-immutable" \
    "${IMMUTABLE}:pull_request" "pull request, immutable"
else
  echo "  WARNING: could not read repo and owner IDs. Run 'gh auth login' and re-run."
fi

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