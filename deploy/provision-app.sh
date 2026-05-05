#!/usr/bin/env bash
# provision-app.sh — create the Azure Container App that runs `claude serve`,
# pulls its image from ACR via a user-assigned managed identity, and exposes
# POST /ask on a public HTTPS ingress.
#
# Satisfies AC 40102 Sub-AC 2: provision the Container App resource referencing
# the ACR-hosted image with the managed identity attached for ACR pull
# authentication. Direct `az` CLI only — no Bicep, no Terraform, no `azd`.
# The Seed forbids IaC for the Container App itself; only the registry has a
# Bicep template (deploy/acr.bicep).
#
# Pre-requisites (run these scripts first, in order):
#   1. deploy/provision-acr.sh        → ACR exists; ACR_NAME is its name.
#   2. deploy/provision-env.sh        → Container Apps environment exists;
#                                       CONTAINERAPPS_ENV is its name.
#   3. deploy/provision-identity.sh   → User-assigned managed identity exists
#                                       with the AcrPull role granted on the ACR;
#                                       IDENTITY_NAME is its name.
#   4. (Optional) deploy/push-image.sh → at least one tagged image exists at
#                                       <ACR>.azurecr.io/<IMAGE_NAME>:<IMAGE_TAG>.
#
# What this script does, in order:
#   1. Confirms `az` is installed, the caller is logged in, and the
#      `containerapp` extension is current (matches provision-env.sh).
#   2. Resolves the user-assigned managed identity's ARM resource ID + clientId
#      from (IDENTITY_NAME, IDENTITY_RESOURCE_GROUP) — fails fast if the UAMI
#      hasn't been provisioned yet.
#   3. Resolves the ACR login server (e.g. claurstacr123.azurecr.io) so the
#      caller doesn't have to remember whether to include `.azurecr.io`.
#   4. Verifies the Container Apps environment exists in the workload group
#      (Sub-AC 2 must not silently materialize a fresh environment — that would
#      bypass provision-env.sh's Log Analytics wiring).
#   5. Creates the Container App if it does not exist, or updates the existing
#      one's image / replica configuration if it does. Both paths leave the app
#      with:
#        - the UAMI attached (`--user-assigned`)
#        - ACR pulls authenticated via that UAMI (`--registry-identity`)
#        - public HTTPS ingress on `--target-port` (default 8080)
#        - exactly one replica (min=max=1, no auto-scale, single revision)
#   6. Sets the platform request-timeout knob (`requestIdleTimeout = 4 minutes`,
#      = 240s) on the ingress to match the Seed's synchronous-blocking AC. The
#      Container Apps default already caps requests at 240s, but pinning the
#      idle timeout keeps the configuration auditable and explicit.
#   7. Prints the public FQDN so the operator can curl POST /ask immediately.
#
# Required env vars (or pass on the command line — see Usage):
#   AZ_RESOURCE_GROUP    Workload resource group (must match provision-env.sh).
#   CONTAINERAPP_NAME    Container App name. 2-32 chars, lowercase alphanumeric
#                        + hyphens; appears as the per-app DNS label.
#                        Convention: claurst-ask.
#   CONTAINERAPPS_ENV    Name of the managed environment from provision-env.sh.
#   ACR_NAME             Name (without `.azurecr.io`) of the registry from
#                        provision-acr.sh.
#   IDENTITY_NAME        Name of the user-assigned managed identity from
#                        provision-identity.sh.
#   IMAGE_TAG            Image tag to deploy (e.g. v0.1.0, latest, $(git rev-parse --short HEAD)).
#                        The image is resolved as
#                        <ACR_NAME>.azurecr.io/<IMAGE_NAME>:<IMAGE_TAG>.
#
# Optional env vars:
#   IMAGE_NAME             Image repo name within the registry (default: claurst-ask).
#   TARGET_PORT            Container port the binary listens on (default: 8080,
#                          matches the Dockerfile's EXPOSE).
#   ACR_RESOURCE_GROUP     Group containing the ACR if separate from
#                          AZ_RESOURCE_GROUP (default: AZ_RESOURCE_GROUP).
#   IDENTITY_RESOURCE_GROUP Group containing the UAMI if separate from
#                          AZ_RESOURCE_GROUP (default: AZ_RESOURCE_GROUP).
#   ENV_RESOURCE_GROUP     Group containing the Container Apps environment if
#                          separate from AZ_RESOURCE_GROUP (default: AZ_RESOURCE_GROUP).
#
# Usage:
#   AZ_RESOURCE_GROUP=rg-claurst \
#   CONTAINERAPP_NAME=claurst-ask \
#   CONTAINERAPPS_ENV=claurst-env \
#   ACR_NAME=claurstacrabc123 \
#   IDENTITY_NAME=claurst-ask-pull \
#   IMAGE_TAG=v0.1.0 \
#   ./deploy/provision-app.sh
#
# Re-running the script with the same inputs is safe: an existing app is
# updated rather than re-created, and image / replica / identity settings are
# all idempotent under the chosen `az containerapp update` invocations.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${AZ_RESOURCE_GROUP:?AZ_RESOURCE_GROUP must be set (e.g. rg-claurst)}"
: "${CONTAINERAPP_NAME:?CONTAINERAPP_NAME must be set (e.g. claurst-ask)}"
: "${CONTAINERAPPS_ENV:?CONTAINERAPPS_ENV must be set (matches provision-env.sh)}"
: "${ACR_NAME:?ACR_NAME must be set (matches provision-acr.sh)}"
: "${IDENTITY_NAME:?IDENTITY_NAME must be set (matches provision-identity.sh)}"
: "${IMAGE_TAG:?IMAGE_TAG must be set (e.g. v0.1.0 or a git SHA)}"

IMAGE_NAME="${IMAGE_NAME:-claurst-ask}"
TARGET_PORT="${TARGET_PORT:-8080}"
ACR_RESOURCE_GROUP="${ACR_RESOURCE_GROUP:-${AZ_RESOURCE_GROUP}}"
IDENTITY_RESOURCE_GROUP="${IDENTITY_RESOURCE_GROUP:-${AZ_RESOURCE_GROUP}}"
ENV_RESOURCE_GROUP="${ENV_RESOURCE_GROUP:-${AZ_RESOURCE_GROUP}}"

# Container App name rules: 2-32 chars, lowercase alphanumeric + hyphens, must
# start and end alphanumeric. Catching this client-side avoids a 5-second
# round-trip to ARM just to learn the name is invalid (mirrors the validation
# pattern in provision-env.sh for the environment name).
if [[ ! "${CONTAINERAPP_NAME}" =~ ^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$ ]]; then
  echo "CONTAINERAPP_NAME='${CONTAINERAPP_NAME}' is invalid: must be 2-32 chars, lowercase alphanumeric or hyphens, starting and ending alphanumeric." >&2
  exit 1
fi

if [[ ! "${ACR_NAME}" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
  echo "ACR_NAME='${ACR_NAME}' is invalid: must be 5-50 alphanumeric characters." >&2
  exit 1
fi

if [[ ! "${IDENTITY_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{2,127}$ ]]; then
  echo "IDENTITY_NAME='${IDENTITY_NAME}' is invalid: must be 3-128 chars, alphanumeric / hyphen / underscore, starting with a letter or digit." >&2
  exit 1
fi

# Target port sanity: must be a positive 16-bit integer. The Dockerfile's
# EXPOSE 8080 is what the binary actually binds to; allowing operators to
# override is purely for unusual side-loaded builds.
if [[ ! "${TARGET_PORT}" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
  echo "TARGET_PORT='${TARGET_PORT}' is invalid: must be an integer between 1 and 65535." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Preflight: az CLI present, authenticated, containerapp extension installed
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
echo ">> Container App:       ${CONTAINERAPP_NAME} (group: ${AZ_RESOURCE_GROUP})"
echo ">> Environment:         ${CONTAINERAPPS_ENV} (group: ${ENV_RESOURCE_GROUP})"
echo ">> Registry:            ${ACR_NAME} (group: ${ACR_RESOURCE_GROUP})"
echo ">> Identity (UAMI):     ${IDENTITY_NAME} (group: ${IDENTITY_RESOURCE_GROUP})"
echo ">> Image:               ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"
echo ">> Target port:         ${TARGET_PORT}"

# `az containerapp` lives in the `containerapp` extension. Modern Azure CLI
# auto-installs on first use, but adding explicitly here makes the script work
# on older `az` versions too (matches provision-env.sh's posture).
echo ">> Ensuring 'containerapp' Azure CLI extension is installed..."
if [ -z "$(az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>/dev/null)" ]; then
    az extension add --name containerapp --only-show-errors --yes --output none
else
    echo "   (already installed; skipping add/upgrade)"
fi

# -----------------------------------------------------------------------------
# Step 1: resolve the user-assigned managed identity
# -----------------------------------------------------------------------------

# We need two fields off the UAMI:
#   • id        — passed to `--user-assigned` (attach the identity to the app)
#                 and `--registry-identity` (use it for ACR auth on pulls).
#   • clientId  — surfaced in the summary block so the operator can sanity-check
#                 the federated client without a second round-trip.
# Failing here means provision-identity.sh hasn't been run; the error message
# points the operator at the right script.
echo ">> Resolving user-assigned managed identity..."
IDENTITY_RESOURCE_ID="$(az identity show \
  --name "${IDENTITY_NAME}" \
  --resource-group "${IDENTITY_RESOURCE_GROUP}" \
  --query id \
  --output tsv 2>/dev/null || true)"

IDENTITY_CLIENT_ID="$(az identity show \
  --name "${IDENTITY_NAME}" \
  --resource-group "${IDENTITY_RESOURCE_GROUP}" \
  --query clientId \
  --output tsv 2>/dev/null || true)"

if [[ -z "${IDENTITY_RESOURCE_ID}" || -z "${IDENTITY_CLIENT_ID}" ]]; then
  echo "User-assigned managed identity '${IDENTITY_NAME}' not found in resource group '${IDENTITY_RESOURCE_GROUP}'." >&2
  echo "Run deploy/provision-identity.sh first, or set IDENTITY_RESOURCE_GROUP if the UAMI lives in a different group." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 2: resolve the ACR login server (and confirm the registry exists)
# -----------------------------------------------------------------------------

# `az acr show --query loginServer` returns `<acr>.azurecr.io`. Resolving from
# the registry record (rather than string-concatenating ourselves) means an
# ACR with a custom data-plane suffix — e.g. an Azure Government tenant with
# `.azurecr.us` — Just Works.
echo ">> Resolving ACR login server..."
ACR_LOGIN_SERVER="$(az acr show \
  --name "${ACR_NAME}" \
  --resource-group "${ACR_RESOURCE_GROUP}" \
  --query loginServer \
  --output tsv 2>/dev/null || true)"

if [[ -z "${ACR_LOGIN_SERVER}" ]]; then
  echo "ACR '${ACR_NAME}' not found in resource group '${ACR_RESOURCE_GROUP}'." >&2
  echo "Run deploy/provision-acr.sh first, or set ACR_RESOURCE_GROUP if the registry lives in a different group." >&2
  exit 1
fi

IMAGE_REF="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

# -----------------------------------------------------------------------------
# Step 3: confirm the Container Apps environment exists
# -----------------------------------------------------------------------------

# We deliberately do *not* create the environment here — that's provision-env.sh's
# job, and silently materialising a fresh one would skip its Log Analytics
# wiring. Surface a clear "run the prereq" error instead.
echo ">> Resolving Container Apps environment..."
ENV_RESOURCE_ID="$(az containerapp env show \
  --name "${CONTAINERAPPS_ENV}" \
  --resource-group "${ENV_RESOURCE_GROUP}" \
  --query id \
  --output tsv 2>/dev/null || true)"

if [[ -z "${ENV_RESOURCE_ID}" ]]; then
  echo "Container Apps environment '${CONTAINERAPPS_ENV}' not found in resource group '${ENV_RESOURCE_GROUP}'." >&2
  echo "Run deploy/provision-env.sh first, or set ENV_RESOURCE_GROUP if the environment lives in a different group." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 4: create or update the Container App
# -----------------------------------------------------------------------------

# Pre-flight existence check: `az containerapp show` exits non-zero when the
# app doesn't exist. Branching on this lets us call `create` only on the first
# run and `update` afterwards, which is the cleanest path to idempotency given
# `az containerapp create` 409s on duplicates.
EXISTING_APP_ID="$(az containerapp show \
  --name "${CONTAINERAPP_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query id \
  --output tsv 2>/dev/null || true)"

if [[ -z "${EXISTING_APP_ID}" ]]; then
  echo ">> Creating Container App '${CONTAINERAPP_NAME}' (this can take a couple of minutes)..."
  # Flag-by-flag rationale:
  #   --environment <id>            : pin the app to the environment provisioned
  #                                   in Step 3 (passing the resource ID instead
  #                                   of the name disambiguates if a same-name
  #                                   environment exists in another group).
  #   --image <ref>                 : ACR-hosted runtime image (Sub-AC 1's
  #                                   build/push satisfies this).
  #   --user-assigned <UAMI id>     : attach the UAMI so the running container
  #                                   inherits the identity (covers any future
  #                                   tool that wants AAD-backed Azure access).
  #   --registry-server <login>     : tell Container Apps which registry to
  #                                   pull from. Required alongside
  #                                   --registry-identity.
  #   --registry-identity <UAMI id> : authenticate ACR pulls via the UAMI's
  #                                   AcrPull grant (provision-identity.sh
  #                                   created this), eliminating the ACR admin
  #                                   password from Container Apps secrets.
  #   --ingress external            : public HTTPS endpoint via the managed
  #                                   reverse proxy (matches the Seed's
  #                                   "public HTTPS ingress" constraint).
  #   --target-port <port>          : the port `claude serve` binds to inside
  #                                   the container (Dockerfile EXPOSE 8080).
  #   --transport auto              : let the platform pick HTTP/1.1 vs HTTP/2
  #                                   based on the request — `claude serve`
  #                                   does plain HTTP/1.1, so this is fine.
  #   --min-replicas 1              : no scale-to-zero — cold starts here would
  #                                   blow past the 240s sync deadline.
  #   --max-replicas 1              : single replica, single revision, no
  #                                   auto-scale (Seed: "single Azure Container
  #                                   Apps instance").
  #   --revisions-mode single       : only one active revision at a time;
  #                                   simplifies the synchronous-traffic story
  #                                   and matches the Seed's "single revision".
  #   --output none                 : silence the verbose JSON; we re-query the
  #                                   FQDN below for the summary block.
  az containerapp create \
    --name "${CONTAINERAPP_NAME}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --environment "${ENV_RESOURCE_ID}" \
    --image "${IMAGE_REF}" \
    --user-assigned "${IDENTITY_RESOURCE_ID}" \
    --registry-server "${ACR_LOGIN_SERVER}" \
    --registry-identity "${IDENTITY_RESOURCE_ID}" \
    --ingress external \
    --target-port "${TARGET_PORT}" \
    --transport auto \
    --min-replicas 1 \
    --max-replicas 1 \
    --revisions-mode single \
    --output none
else
  echo ">> Container App '${CONTAINERAPP_NAME}' already exists — updating image and replica config..."
  # On the update path we don't repeat `--environment` (immutable) or
  # `--ingress` (its own subcommand). The four flags below are the ones that
  # safely converge a previously-deployed app to the desired state on every
  # re-run:
  #   --image            : roll forward to the new tag.
  #   --min/max-replicas : reaffirm the single-replica posture in case a
  #                        previous run customised it via the portal.
  #   --revisions-mode   : same reason — keep `single` revision mode pinned.
  az containerapp update \
    --name "${CONTAINERAPP_NAME}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --image "${IMAGE_REF}" \
    --min-replicas 1 \
    --max-replicas 1 \
    --revisions-mode single \
    --output none

  # Identity attachment and ACR-pull-via-identity have to be re-asserted via
  # their dedicated subcommands; `az containerapp update` doesn't accept the
  # `--user-assigned` / `--registry-identity` flags (those are create-only).
  # Both calls below are idempotent and no-op on the existing config.
  echo ">> Ensuring user-assigned identity is attached..."
  az containerapp identity assign \
    --name "${CONTAINERAPP_NAME}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --user-assigned "${IDENTITY_RESOURCE_ID}" \
    --output none

  echo ">> Ensuring ACR pulls authenticate via the UAMI..."
  az containerapp registry set \
    --name "${CONTAINERAPP_NAME}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --server "${ACR_LOGIN_SERVER}" \
    --identity "${IDENTITY_RESOURCE_ID}" \
    --output none
fi

# -----------------------------------------------------------------------------
# Step 5: pin the ingress idle timeout to 4 minutes (240s)
# -----------------------------------------------------------------------------

# Container Apps' HTTP request idle timeout is `ingress.idleTimeoutInMinutes`.
# 4 minutes = 240s, which matches the Seed's synchronous-blocking AC. The
# platform default already caps at 240s, but pinning the value explicitly:
#   • makes the configuration auditable (visible in `az containerapp show`),
#   • survives any future platform default change without a silent regression,
#   • mirrors the Seed's `request_timeout_seconds` ontology concept.
#
# `az containerapp ingress update --idle-timeout-in-minutes` has been the
# stable setter since the May-2024 CLI release. Older CLI versions silently
# ignore unknown flags and exit 2; we tolerate that by allowing the call to
# fail soft and warning the operator to upgrade if so.
echo ">> Setting ingress idle timeout to 4 minutes (240s)..."
if ! az containerapp ingress update \
      --name "${CONTAINERAPP_NAME}" \
      --resource-group "${AZ_RESOURCE_GROUP}" \
      --idle-timeout-in-minutes 4 \
      --output none 2>/dev/null; then
  echo "   (ingress idle-timeout setter unavailable on this az version — the platform default of 240s still applies; upgrade az to silence this notice.)" >&2
fi

# -----------------------------------------------------------------------------
# Step 6: surface the public FQDN and next-step commands
# -----------------------------------------------------------------------------

APP_FQDN="$(az containerapp show \
  --name "${CONTAINERAPP_NAME}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.ingress.fqdn \
  --output tsv)"

cat <<EOF

>> Container App provisioning complete.
   Container App:   ${CONTAINERAPP_NAME}
   Resource group:  ${AZ_RESOURCE_GROUP}
   Environment:     ${CONTAINERAPPS_ENV}
   Image:           ${IMAGE_REF}
   UAMI clientId:   ${IDENTITY_CLIENT_ID}
   Public FQDN:     https://${APP_FQDN}

   Next steps:

   # 1. Wire the Container Apps secrets (DEEPSEEK_API_KEY + CLAURST_API_KEY).
   #    Required before the first request — the binary refuses to start
   #    without them.
   AZ_RESOURCE_GROUP=${AZ_RESOURCE_GROUP} \\
   AZ_CONTAINERAPP=${CONTAINERAPP_NAME} \\
   DEEPSEEK_API_KEY=sk-... \\
   CLAURST_API_KEY=\$(openssl rand -hex 32) \\
     ./deploy/secrets/setup-secrets.sh

   # 2. Smoke-test the endpoint:
   curl -sSf -X POST https://${APP_FQDN}/ask \\
     -H "X-API-Key: \${CLAURST_API_KEY}" \\
     -H 'Content-Type: application/json' \\
     -d '{"question":"What is the capital of France?"}'

   # 3. Tail logs:
   az containerapp logs show \\
     --name ${CONTAINERAPP_NAME} \\
     --resource-group ${AZ_RESOURCE_GROUP} \\
     --follow

EOF
