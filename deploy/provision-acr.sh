#!/usr/bin/env bash
# provision-acr.sh — create the resource group and deploy acr.bicep.
#
# Satisfies Sub-AC 3.2: a single, idempotent script that takes the deploy/acr.bicep
# template from source control and lands a real Azure Container Registry that the
# Container Apps revision (running `claude serve`) will pull the runtime image
# from. Direct `az` CLI only — no Terraform, no `azd`, no separate IaC orchestrator.
#
# What this script does, in order:
#   1. Confirms `az` is installed and the caller is logged in (`az account show`).
#   2. Creates the resource group if it does not already exist (idempotent).
#   3. Deploys deploy/acr.bicep into that group with the supplied registry name.
#   4. Captures the deployment outputs (`loginServer`, `adminUsername`) and prints
#      the next-step `docker push` / `az containerapp create` commands wired to
#      those values, so the operator can copy/paste straight into the next AC.
#
# Required env vars (or pass on the command line — see Usage):
#   AZ_RESOURCE_GROUP    Resource group to create / deploy into (e.g. rg-claurst)
#   AZ_LOCATION          Azure region for the group + registry (e.g. eastus)
#   ACR_NAME             Globally-unique registry name, 5-50 alphanumerics only
#                        (forms <ACR_NAME>.azurecr.io). Convention: claurstacr<suffix>.
#
# Optional env vars:
#   ACR_SKU              Basic | Standard | Premium  (default: Basic — see acr.bicep)
#   DEPLOYMENT_NAME      Name for the ARM deployment record (default: acr-<timestamp>)
#
# Usage:
#   AZ_RESOURCE_GROUP=rg-claurst \
#   AZ_LOCATION=eastus \
#   ACR_NAME=claurstacr$(openssl rand -hex 3) \
#   ./deploy/provision-acr.sh
#
# Re-running the script with the same inputs is safe: `az group create` and
# `az deployment group create` are both idempotent — the deployment will produce
# a no-op change set if nothing in acr.bicep has changed.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${AZ_RESOURCE_GROUP:?AZ_RESOURCE_GROUP must be set (e.g. rg-claurst)}"
: "${AZ_LOCATION:?AZ_LOCATION must be set (e.g. eastus)}"
: "${ACR_NAME:?ACR_NAME must be set (5-50 alphanumeric chars, globally unique)}"

ACR_SKU="${ACR_SKU:-Basic}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-acr-$(date -u +%Y%m%d%H%M%S)}"

# Resolve the bicep file relative to this script so the operator can invoke it
# from any working directory. `BASH_SOURCE[0]` is the script path; `dirname`
# strips the filename, leaving the deploy/ directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/acr.bicep"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "Bicep template not found at ${TEMPLATE_FILE}" >&2
  exit 1
fi

# Registry name validation mirrors the Bicep @minLength/@maxLength constraints
# and ACR's "alphanumeric only" rule. Catching this client-side avoids a 5-second
# round-trip to ARM just to learn the name is invalid.
if [[ ! "${ACR_NAME}" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
  echo "ACR_NAME='${ACR_NAME}' is invalid: must be 5-50 alphanumeric characters." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Preflight: az CLI present and authenticated
# -----------------------------------------------------------------------------

if ! command -v az >/dev/null 2>&1; then
  echo "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI" >&2
  exit 1
fi

# `az account show` exits non-zero when the caller is not logged in. Showing
# the active subscription gives the operator a chance to catch a wrong-
# subscription mistake before the deployment lands real money.
if ! az account show --output none 2>/dev/null; then
  echo "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first." >&2
  exit 1
fi

SUBSCRIPTION_NAME="$(az account show --query name --output tsv)"
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

echo ">> Active subscription: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"
echo ">> Target resource group: ${AZ_RESOURCE_GROUP} (${AZ_LOCATION})"
echo ">> Registry: ${ACR_NAME} [SKU=${ACR_SKU}]"

# -----------------------------------------------------------------------------
# Step 1: ensure the resource group exists
# -----------------------------------------------------------------------------

# `az group create` is idempotent: if the group already exists in the requested
# location, ARM returns the existing record without modification. This is why we
# don't bother with `az group exists` first — one call is simpler and faster.
echo ">> Ensuring resource group exists..."
az group create \
  --name "${AZ_RESOURCE_GROUP}" \
  --location "${AZ_LOCATION}" \
  --output none

# -----------------------------------------------------------------------------
# Step 2: deploy the ACR Bicep template
# -----------------------------------------------------------------------------

echo ">> Deploying ${TEMPLATE_FILE} as deployment '${DEPLOYMENT_NAME}'..."
# Suppress noisy ARM JSON on success — we re-query the outputs below so the
# summary block stays the script's only "look here" output.
az deployment group create \
  --name "${DEPLOYMENT_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters \
    "registryName=${ACR_NAME}" \
    "location=${AZ_LOCATION}" \
    "sku=${ACR_SKU}" \
  --output none

# Pull outputs out of the deployment record. The Bicep file declares
# `loginServer`, `registryId`, and `adminUsername` as outputs; we surface the
# two the operator actually copy/pastes into the next step.
LOGIN_SERVER="$(az deployment group show \
  --name "${DEPLOYMENT_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query 'properties.outputs.loginServer.value' \
  --output tsv)"

ADMIN_USERNAME="$(az deployment group show \
  --name "${DEPLOYMENT_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query 'properties.outputs.adminUsername.value' \
  --output tsv)"

# -----------------------------------------------------------------------------
# Step 3: surface the next-step commands using the deployment outputs
# -----------------------------------------------------------------------------

cat <<EOF

>> ACR provisioning complete.
   Login server: ${LOGIN_SERVER}
   Admin user:   ${ADMIN_USERNAME}

   Next steps (copy/paste, then fill in <tag> and <containerapp>):

   # 1. Build & push the image to the new registry:
   az acr login --name ${ACR_NAME}
   docker build -t ${LOGIN_SERVER}/claurst-ask:<tag> .
   docker push ${LOGIN_SERVER}/claurst-ask:<tag>

   # 2. Retrieve the admin password (for Container Apps registry auth):
   az acr credential show --name ${ACR_NAME} --query 'passwords[0].value' -o tsv

   # 3. Wire the registry into a Container App revision:
   az containerapp create \\
     --name <containerapp> \\
     --resource-group ${AZ_RESOURCE_GROUP} \\
     --image ${LOGIN_SERVER}/claurst-ask:<tag> \\
     --registry-server ${LOGIN_SERVER} \\
     --registry-username ${ADMIN_USERNAME} \\
     --registry-password '<paste-from-step-2>'

EOF
