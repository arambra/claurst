#!/usr/bin/env bash
# provision-env.sh — create the resource group, Log Analytics workspace, and
# Azure Container Apps Environment that the `claude serve` revision will run in.
#
# Satisfies AC 5 Sub-AC 1: a single, idempotent script that lands the
# Container Apps managed environment (with its required Log Analytics
# workspace) in the target resource group + region. Direct `az` CLI only —
# no Bicep, no Terraform, no `azd`. The Seed explicitly forbids IaC for
# anything beyond the pre-existing ACR template.
#
# Resource hierarchy this script creates / ensures (idempotent at every step):
#   <AZ_RESOURCE_GROUP>          (resource group, region = AZ_LOCATION)
#     ├── <LAW_NAME>             (Log Analytics workspace, PerGB2018 SKU)
#     └── <CONTAINERAPPS_ENV>    (Container Apps managed environment, wired
#                                 to the LAW for stdout/stderr → KQL queries)
#
# Why a Log Analytics workspace? Container Apps requires a destination for the
# environment-level diagnostic stream. Without it, `az containerapp env create`
# would either fail or silently default to a workspace it manages for you,
# which we cannot inspect or query later. Pinning the LAW name here lets the
# operator run `az monitor log-analytics query` against `ContainerAppConsoleLogs_CL`
# when the deployed `/ask` endpoint misbehaves.
#
# Required env vars (or pass on the command line — see Usage):
#   AZ_RESOURCE_GROUP    Resource group to create / deploy into (e.g. rg-claurst).
#                        Should match the group used for provision-acr.sh so the
#                        registry, environment, and container app live together.
#   AZ_LOCATION          Azure region for the group, workspace, and environment
#                        (e.g. eastus). Must be a region where the Container Apps
#                        service is available — see https://aka.ms/containerapps-regions.
#   CONTAINERAPPS_ENV    Name for the managed environment (e.g. claurst-env).
#                        2-32 chars, lowercase letters / digits / hyphens; the
#                        name appears as a DNS label so we validate that here.
#
# Optional env vars:
#   LAW_NAME             Log Analytics workspace name (default: ${CONTAINERAPPS_ENV}-law).
#                        4-63 chars, must start/end alphanumeric, hyphens allowed.
#
# Usage:
#   AZ_RESOURCE_GROUP=rg-claurst \
#   AZ_LOCATION=eastus \
#   CONTAINERAPPS_ENV=claurst-env \
#   ./deploy/provision-env.sh
#
# Re-running the script with the same inputs is safe: every `az` call below
# is either inherently idempotent (`az group create`) or guarded by a pre-flight
# existence check.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${AZ_RESOURCE_GROUP:?AZ_RESOURCE_GROUP must be set (e.g. rg-claurst)}"
: "${AZ_LOCATION:?AZ_LOCATION must be set (e.g. eastus)}"
: "${CONTAINERAPPS_ENV:?CONTAINERAPPS_ENV must be set (e.g. claurst-env)}"

# Default the workspace name to "<env>-law". The "-law" suffix follows the
# pattern Microsoft uses in their own quickstart docs and keeps the relationship
# obvious in the portal/CLI listing.
LAW_NAME="${LAW_NAME:-${CONTAINERAPPS_ENV}-law}"

# Container Apps environment names form part of the per-app DNS label
# (<app>.<random>.<region>.azurecontainerapps.io). Validating client-side
# avoids a 5-second round-trip to ARM just to learn the name is invalid.
if [[ ! "${CONTAINERAPPS_ENV}" =~ ^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$ ]]; then
  echo "CONTAINERAPPS_ENV='${CONTAINERAPPS_ENV}' is invalid: must be 2-32 chars, lowercase alphanumeric or hyphens, starting and ending alphanumeric." >&2
  exit 1
fi

# Log Analytics workspace name rules (per ARM spec): 4-63 chars,
# alphanumeric or hyphen, must start and end alphanumeric.
if [[ ! "${LAW_NAME}" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9]{2,61}[a-zA-Z0-9])$ ]]; then
  echo "LAW_NAME='${LAW_NAME}' is invalid: must be 4-63 chars, alphanumeric or hyphen, starting and ending alphanumeric." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Preflight: az CLI present and authenticated
# -----------------------------------------------------------------------------

if ! command -v az >/dev/null 2>&1; then
  echo "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI" >&2
  exit 1
fi

if ! az account show --output none 2>/dev/null; then
  echo "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first." >&2
  exit 1
fi

SUBSCRIPTION_NAME="$(az account show --query name --output tsv)"
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

echo ">> Active subscription: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"
echo ">> Target resource group: ${AZ_RESOURCE_GROUP} (${AZ_LOCATION})"
echo ">> Container Apps environment: ${CONTAINERAPPS_ENV}"
echo ">> Log Analytics workspace:    ${LAW_NAME}"

# -----------------------------------------------------------------------------
# Step 0: resource provider registration & containerapp extension
# -----------------------------------------------------------------------------

# `Microsoft.App` is the RP for Container Apps; `Microsoft.OperationalInsights`
# is the RP for Log Analytics. Both are usually pre-registered on a mature
# subscription, but a fresh sub will silently 404 the create calls below if
# they aren't, with an opaque error. Register first — it's a no-op if already
# registered.
echo ">> Ensuring Microsoft.App and Microsoft.OperationalInsights providers are registered..."
az provider register --namespace Microsoft.App --wait --output none
az provider register --namespace Microsoft.OperationalInsights --wait --output none

# `az containerapp env create` lives in the `containerapp` extension. Modern
# Azure CLI auto-installs on first use, but adding explicitly here makes the
# script work on older `az` versions too.
echo ">> Ensuring 'containerapp' Azure CLI extension is installed..."
if [ -z "$(az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>/dev/null)" ]; then
    az extension add --name containerapp --only-show-errors --yes --output none
else
    echo "   (already installed; skipping add/upgrade)"
fi

# -----------------------------------------------------------------------------
# Step 1: ensure the resource group exists
# -----------------------------------------------------------------------------

# `az group create` is idempotent: if the group already exists in the requested
# location, ARM returns the existing record without modification.
echo ">> Ensuring resource group exists..."
az group create \
  --name "${AZ_RESOURCE_GROUP}" \
  --location "${AZ_LOCATION}" \
  --output none

# -----------------------------------------------------------------------------
# Step 2: ensure the Log Analytics workspace exists
# -----------------------------------------------------------------------------

# `az monitor log-analytics workspace create` returns the existing workspace
# (and exits 0) if a workspace with the same name already exists in the group.
# We pin the SKU to PerGB2018 — the only generally-available SKU since 2020
# and the one assumed by `az containerapp env create` defaults.
echo ">> Ensuring Log Analytics workspace '${LAW_NAME}' exists..."
az monitor log-analytics workspace create \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --workspace-name "${LAW_NAME}" \
  --location "${AZ_LOCATION}" \
  --sku PerGB2018 \
  --output none

# Pull the workspace identifiers the Container Apps environment needs to be
# wired to the LAW. `customer-id` is the workspace GUID, `primarySharedKey`
# is the ingest key — both are required by `az containerapp env create
# --logs-workspace-{id,key}`.
LAW_CUSTOMER_ID="$(az monitor log-analytics workspace show \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --workspace-name "${LAW_NAME}" \
  --query customerId \
  --output tsv)"

LAW_SHARED_KEY="$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --workspace-name "${LAW_NAME}" \
  --query primarySharedKey \
  --output tsv)"

if [[ -z "${LAW_CUSTOMER_ID}" || -z "${LAW_SHARED_KEY}" ]]; then
  echo "Failed to retrieve Log Analytics workspace credentials — aborting." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 3: ensure the Container Apps managed environment exists
# -----------------------------------------------------------------------------

# Pre-flight check before issuing the create call: `az containerapp env show`
# exits non-zero when the environment doesn't exist. We use this to keep the
# "already created" path silent and avoid spurious error noise from the
# create command's overly chatty failure mode on duplicate names.
EXISTING_ENV_ID="$(az containerapp env show \
  --name "${CONTAINERAPPS_ENV}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query id \
  --output tsv 2>/dev/null || true)"

if [[ -n "${EXISTING_ENV_ID}" ]]; then
  echo ">> Container Apps environment '${CONTAINERAPPS_ENV}' already exists — skipping create."
else
  echo ">> Creating Container Apps environment '${CONTAINERAPPS_ENV}' (this can take a few minutes)..."
  az containerapp env create \
    --name "${CONTAINERAPPS_ENV}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --location "${AZ_LOCATION}" \
    --logs-workspace-id "${LAW_CUSTOMER_ID}" \
    --logs-workspace-key "${LAW_SHARED_KEY}" \
    --output none
fi

# Re-query to surface a single canonical environment ID for the summary block.
ENV_ID="$(az containerapp env show \
  --name "${CONTAINERAPPS_ENV}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query id \
  --output tsv)"

ENV_DEFAULT_DOMAIN="$(az containerapp env show \
  --name "${CONTAINERAPPS_ENV}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.defaultDomain \
  --output tsv)"

# -----------------------------------------------------------------------------
# Step 4: surface the next-step commands for the operator
# -----------------------------------------------------------------------------

cat <<EOF

>> Container Apps environment provisioning complete.
   Environment ID:  ${ENV_ID}
   Default domain:  ${ENV_DEFAULT_DOMAIN}
   Log Analytics:   ${LAW_NAME} (workspace ID ${LAW_CUSTOMER_ID})

   Next steps (copy/paste, then fill in <acrname>, <tag>, registry-password):

   # Wire the registry into a Container App revision inside this environment:
   az containerapp create \\
     --name claurst-ask \\
     --resource-group ${AZ_RESOURCE_GROUP} \\
     --environment ${CONTAINERAPPS_ENV} \\
     --image <acrname>.azurecr.io/claurst-ask:<tag> \\
     --registry-server <acrname>.azurecr.io \\
     --registry-username <acrname> \\
     --registry-password '<paste-from-acr-credential-show>' \\
     --ingress external \\
     --target-port 8080 \\
     --min-replicas 1 \\
     --max-replicas 1

   # Tail logs once the app is running:
   az containerapp logs show \\
     --name claurst-ask \\
     --resource-group ${AZ_RESOURCE_GROUP} \\
     --follow

EOF
