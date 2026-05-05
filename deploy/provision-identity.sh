#!/usr/bin/env bash
# provision-identity.sh — create a user-assigned managed identity (UAMI) and
# grant it AcrPull on the target Azure Container Registry.
#
# Satisfies AC 40101 Sub-AC 1: a single, idempotent script that lands the
# identity the Container Apps revision will use to pull the runtime image
# from ACR — eliminating the need to ship the registry's admin password as
# a Container Apps secret. Direct `az` CLI only — no Bicep, no Terraform,
# no `azd`. The Seed explicitly forbids IaC for anything beyond the
# pre-existing ACR template.
#
# Why a UAMI (and not the ACR admin user / a system-assigned identity)?
#   • UAMI lifecycle is independent of the Container App: we can roll the app
#     image, recreate the revision, or even delete the app, and the identity +
#     its role assignment survive. That keeps Sub-AC 2 (wiring the identity
#     into `az containerapp create`) and Sub-AC 3 (granting access) cleanly
#     decoupled from the workload's lifecycle.
#   • UAMI gets an explicit principalId we can role-assign here, before the
#     Container App exists. A system-assigned identity would force us to
#     create the app first, then bolt the role on after — fragile and harder
#     to make idempotent.
#   • Avoids storing ACR admin credentials in Container Apps secrets, which
#     the Seed's "no Key Vault" + "secrets-only-for-DeepSeek/X-API-Key"
#     posture would otherwise require.
#
# What this script does, in order:
#   1. Confirms `az` is installed and the caller is logged in (`az account show`).
#   2. Ensures the resource group exists (idempotent — same pattern as
#      provision-acr.sh and provision-env.sh).
#   3. Creates the user-assigned managed identity if it doesn't already exist.
#   4. Resolves the ACR resource ID and the UAMI principalId.
#   5. Grants the UAMI the built-in `AcrPull` role (scope = the ACR), guarded
#      by an existence check so re-runs are no-ops.
#   6. Prints the identity resource ID + clientId + principalId, plus the
#      next-step `az containerapp create` snippet wired to those values.
#
# Required env vars (or pass on the command line — see Usage):
#   AZ_RESOURCE_GROUP    Resource group to create / deploy into (e.g. rg-claurst).
#                        Should match the group used by provision-acr.sh /
#                        provision-env.sh so the registry, environment, identity,
#                        and container app live together.
#   AZ_LOCATION          Azure region for the group + identity (e.g. eastus).
#                        UAMIs are regional; pin them to the same region as the
#                        Container Apps environment to avoid cross-region calls
#                        on every image pull.
#   IDENTITY_NAME        Name for the user-assigned managed identity
#                        (e.g. claurst-ask-pull). 3-128 chars, alphanumerics +
#                        hyphens / underscores; must start with a letter or
#                        digit. Convention: <containerapp>-pull.
#   ACR_NAME             Name of the existing Azure Container Registry that the
#                        identity needs AcrPull on. Must be a registry already
#                        provisioned by deploy/provision-acr.sh; we resolve its
#                        resourceId by name rather than asking the operator to
#                        paste it (less to get wrong).
#
# Optional env vars:
#   ACR_RESOURCE_GROUP   Resource group containing the ACR if different from
#                        AZ_RESOURCE_GROUP (defaults to AZ_RESOURCE_GROUP).
#                        Useful if the registry is shared across environments
#                        and lives in a separate "platform" group.
#
# Usage:
#   AZ_RESOURCE_GROUP=rg-claurst \
#   AZ_LOCATION=eastus \
#   IDENTITY_NAME=claurst-ask-pull \
#   ACR_NAME=claurstacrabc123 \
#   ./deploy/provision-identity.sh
#
# Re-running the script with the same inputs is safe at every step: the
# identity create call returns the existing record if the name is taken in the
# group, and the role-assignment block is guarded by an existence check.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${AZ_RESOURCE_GROUP:?AZ_RESOURCE_GROUP must be set (e.g. rg-claurst)}"
: "${AZ_LOCATION:?AZ_LOCATION must be set (e.g. eastus)}"
: "${IDENTITY_NAME:?IDENTITY_NAME must be set (e.g. claurst-ask-pull)}"
: "${ACR_NAME:?ACR_NAME must be set (name of the existing registry)}"

# If the ACR lives in a different group from the Container App workload (a
# common "shared platform registry" pattern), let the operator point the
# scope lookup at it explicitly. Default to the same group otherwise.
ACR_RESOURCE_GROUP="${ACR_RESOURCE_GROUP:-${AZ_RESOURCE_GROUP}}"

# UAMI name rules (per ARM spec): 3-128 chars, alphanumeric / hyphen /
# underscore, must start with a letter or digit. Catching this client-side
# avoids a 5-second round-trip to ARM just to learn the name is invalid.
if [[ ! "${IDENTITY_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{2,127}$ ]]; then
  echo "IDENTITY_NAME='${IDENTITY_NAME}' is invalid: must be 3-128 chars, alphanumeric / hyphen / underscore, starting with a letter or digit." >&2
  exit 1
fi

# Mirror the ACR name validation from provision-acr.sh so a typo here gets
# caught locally instead of as a 404 from `az acr show`.
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

if ! az account show --output none 2>/dev/null; then
  echo "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first." >&2
  exit 1
fi

SUBSCRIPTION_NAME="$(az account show --query name --output tsv)"
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

echo ">> Active subscription: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"
echo ">> Target resource group: ${AZ_RESOURCE_GROUP} (${AZ_LOCATION})"
echo ">> Identity:              ${IDENTITY_NAME}"
echo ">> Registry:              ${ACR_NAME} (group: ${ACR_RESOURCE_GROUP})"

# -----------------------------------------------------------------------------
# Step 0: ensure resource provider is registered
# -----------------------------------------------------------------------------

# `Microsoft.ManagedIdentity` is the RP for user-assigned identities. Usually
# pre-registered, but a fresh subscription will silently 404 the create call
# below if it isn't. Register first — it's a no-op if already registered.
echo ">> Ensuring Microsoft.ManagedIdentity provider is registered..."
az provider register --namespace Microsoft.ManagedIdentity --wait --output none

# -----------------------------------------------------------------------------
# Step 1: ensure the resource group exists
# -----------------------------------------------------------------------------

echo ">> Ensuring resource group exists..."
az group create \
  --name "${AZ_RESOURCE_GROUP}" \
  --location "${AZ_LOCATION}" \
  --output none

# -----------------------------------------------------------------------------
# Step 2: ensure the user-assigned managed identity exists
# -----------------------------------------------------------------------------

# `az identity create` returns the existing identity (and exits 0) when an
# identity with the same name already exists in the group, so the call is
# safely idempotent. We capture the principalId, clientId, and resourceId
# in one shot to avoid a second round-trip via `az identity show`.
echo ">> Ensuring user-assigned managed identity '${IDENTITY_NAME}' exists..."
az identity create \
  --name "${IDENTITY_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --location "${AZ_LOCATION}" \
  --output none

# Re-query for a canonical, machine-readable view. We want three fields:
#   • principalId  — the AAD object ID we role-assign in step 4
#   • clientId     — the OAuth client ID the running container will federate as
#   • id           — the ARM resource ID we hand to `az containerapp create
#                    --user-assigned` and `--registry-identity` in Sub-AC 2
IDENTITY_PRINCIPAL_ID="$(az identity show \
  --name "${IDENTITY_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query principalId \
  --output tsv)"

IDENTITY_CLIENT_ID="$(az identity show \
  --name "${IDENTITY_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query clientId \
  --output tsv)"

IDENTITY_RESOURCE_ID="$(az identity show \
  --name "${IDENTITY_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query id \
  --output tsv)"

if [[ -z "${IDENTITY_PRINCIPAL_ID}" || -z "${IDENTITY_CLIENT_ID}" || -z "${IDENTITY_RESOURCE_ID}" ]]; then
  echo "Failed to retrieve identity properties for '${IDENTITY_NAME}' — aborting." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 3: resolve the target ACR's resource ID
# -----------------------------------------------------------------------------

# `az acr show` exits non-zero with a 404 when the registry doesn't exist.
# Surface that as a precise error rather than letting `az role assignment
# create` fail later with a generic "scope is invalid" message.
ACR_RESOURCE_ID="$(az acr show \
  --name "${ACR_NAME}" \
  --resource-group "${ACR_RESOURCE_GROUP}" \
  --query id \
  --output tsv 2>/dev/null || true)"

if [[ -z "${ACR_RESOURCE_ID}" ]]; then
  echo "ACR '${ACR_NAME}' not found in resource group '${ACR_RESOURCE_GROUP}'." >&2
  echo "Run deploy/provision-acr.sh first, or set ACR_RESOURCE_GROUP if the registry lives in a different group." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 4: grant the identity AcrPull on the registry (idempotent)
# -----------------------------------------------------------------------------

# Pre-flight existence check: `az role assignment list` filters by
# (assignee, role, scope). If the assignment already exists, skip the create
# call — `az role assignment create` is *not* fully idempotent on duplicates
# (it returns a 409 with a non-zero exit code, which would break re-runs).
#
# Note on `--assignee-object-id` + `--assignee-principal-type ServicePrincipal`:
# we use the principalId (AAD object ID) directly rather than the clientId.
# This avoids a Graph lookup that fails on freshly-created identities (the
# AAD propagation race). For a UAMI, principal-type is always ServicePrincipal.
echo ">> Checking for existing AcrPull role assignment..."
EXISTING_ASSIGNMENT_ID="$(az role assignment list \
  --assignee-object-id "${IDENTITY_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role AcrPull \
  --scope "${ACR_RESOURCE_ID}" \
  --query '[0].id' \
  --output tsv 2>/dev/null || true)"

if [[ -n "${EXISTING_ASSIGNMENT_ID}" ]]; then
  echo ">> AcrPull already granted to '${IDENTITY_NAME}' on '${ACR_NAME}' — skipping."
else
  echo ">> Granting AcrPull on '${ACR_NAME}' to '${IDENTITY_NAME}'..."
  # Retry loop: AAD takes a few seconds to propagate a freshly-created UAMI's
  # principalId across the tenant. Without this, the first call after `az
  # identity create` can fail with "Principal does not exist in directory".
  # 5 retries × 6s = 30s ceiling, which is plenty for the typical 5-15s
  # propagation window.
  attempts=0
  until az role assignment create \
    --assignee-object-id "${IDENTITY_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role AcrPull \
    --scope "${ACR_RESOURCE_ID}" \
    --output none 2>/dev/null; do
    attempts=$((attempts + 1))
    if (( attempts >= 5 )); then
      echo "Failed to create AcrPull role assignment after ${attempts} attempts." >&2
      # Re-run once without `2>/dev/null` so the operator sees the underlying
      # error (likely a permissions issue — Owner/RBAC Admin needed on the ACR).
      az role assignment create \
        --assignee-object-id "${IDENTITY_PRINCIPAL_ID}" \
        --assignee-principal-type ServicePrincipal \
        --role AcrPull \
        --scope "${ACR_RESOURCE_ID}"
      exit 1
    fi
    echo "   (attempt ${attempts} failed, retrying in 6s — likely AAD propagation delay)"
    sleep 6
  done
fi

# -----------------------------------------------------------------------------
# Step 5: surface the next-step commands using the identity outputs
# -----------------------------------------------------------------------------

cat <<EOF

>> Identity provisioning complete.
   Identity name:        ${IDENTITY_NAME}
   Resource ID:          ${IDENTITY_RESOURCE_ID}
   Client ID:            ${IDENTITY_CLIENT_ID}
   Principal ID:         ${IDENTITY_PRINCIPAL_ID}
   AcrPull granted on:   ${ACR_RESOURCE_ID}

   Next step (Sub-AC 2 wires this identity into the Container App revision so
   image pulls authenticate via the UAMI instead of admin credentials):

   az containerapp create \\
     --name claurst-ask \\
     --resource-group ${AZ_RESOURCE_GROUP} \\
     --environment <containerapp-env> \\
     --image ${ACR_NAME}.azurecr.io/claurst-ask:<tag> \\
     --user-assigned ${IDENTITY_RESOURCE_ID} \\
     --registry-server ${ACR_NAME}.azurecr.io \\
     --registry-identity ${IDENTITY_RESOURCE_ID} \\
     --ingress external \\
     --target-port 8080 \\
     --min-replicas 1 \\
     --max-replicas 1

EOF
