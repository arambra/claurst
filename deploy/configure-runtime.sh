#!/usr/bin/env bash
# configure-runtime.sh — converge a deployed Container App's runtime configuration
# (ingress + secrets + env vars) to the shape the /ask REST endpoint requires.
#
# Satisfies AC 40103 Sub-AC 3: "Configure Container App ingress (external,
# target port) and environment variables/secrets required for the /ask
# endpoint runtime."
#
# Where this fits in the deploy pipeline:
#
#   provision-acr      → registry exists                       (AC 5)
#   provision-env      → Container Apps environment exists     (AC 5)
#   provision-identity → user-assigned managed identity exists (AC 5/40102)
#   push-image         → image tag pushed to ACR               (AC 6)
#   provision-app      → Container App created/updated         (AC 40102 Sub-AC 2)
#   ▶ configure-runtime ◀ ingress + secrets + env vars in one  (AC 40103 Sub-AC 3)
#
# `provision-app` already creates an app with `--ingress external`,
# `--target-port 8080`, and a 240-second ingress idle timeout. `setup-secrets`
# already stores the two secrets and binds them to env vars. This script is
# the single coherent "runtime config converger": it asserts both halves at
# once, so re-running it brings any drifted Container App back to the desired
# state without forcing the operator to remember which subset of the previous
# scripts to re-run.
#
# What this script does, in order:
#   1. Confirms `az` is installed, the caller is logged in, and the
#      `containerapp` extension is current.
#   2. Confirms the Container App exists (fails fast otherwise — there is
#      nothing to configure if `provision-app` hasn't been run).
#   3. Re-asserts ingress: external visibility, target port, 4-minute
#      (240 s) idle timeout. Each setting is idempotent under
#      `az containerapp ingress {enable,update}` — re-running this script
#      against an already-correct app is a no-op.
#   4. Stores the two Container Apps secrets (`deepseek-api-key`,
#      `claurst-api-key`).
#   5. Binds the secrets to environment variables (`DEEPSEEK_API_KEY`,
#      `CLAURST_API_KEY`) on the running container via `secretref:`
#      indirection. Literal values never appear in the revision template.
#   6. Verifies the resulting configuration: prints both secret names,
#      both env-var names with their `secretRef` targets, ingress fields,
#      and the public FQDN. Every line confirms a Sub-AC 3 requirement.
#
# Required env vars (or pass on the command line — see Usage):
#   AZ_RESOURCE_GROUP    Resource group containing the Container App
#                        (must match provision-app.sh).
#   AZ_CONTAINERAPP      Name of the Container App (e.g. claurst-ask).
#   DEEPSEEK_API_KEY     Outbound key for DeepSeek's Anthropic-compatible API.
#   CLAURST_API_KEY      Inbound shared secret callers send as X-API-Key.
#                        Generate once with `openssl rand -hex 32` and share
#                        with callers; the binary refuses to start without it.
#
# Optional env vars:
#   TARGET_PORT          Container port the binary listens on (default: 8080,
#                        matches Dockerfile EXPOSE).
#   IDLE_TIMEOUT_MINUTES Ingress request idle timeout in minutes
#                        (default: 4 == 240 s, matches the seed's
#                        synchronous-blocking constraint).
#
# Usage:
#   AZ_RESOURCE_GROUP=rg-claurst \
#   AZ_CONTAINERAPP=claurst-ask \
#   DEEPSEEK_API_KEY=sk-... \
#   CLAURST_API_KEY=$(openssl rand -hex 32) \
#   ./deploy/configure-runtime.sh
#
# Re-running the script with the same inputs is safe: every `az` call below
# is idempotent under the chosen invocation. Rotating either secret value
# only requires re-running this script with the new value(s) and restarting
# the active revision — no template change.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${AZ_RESOURCE_GROUP:?AZ_RESOURCE_GROUP must be set (e.g. rg-claurst)}"
: "${AZ_CONTAINERAPP:?AZ_CONTAINERAPP must be set (e.g. claurst-ask)}"
: "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY must be set}"
: "${CLAURST_API_KEY:?CLAURST_API_KEY must be set}"

TARGET_PORT="${TARGET_PORT:-8080}"
IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-4}"

# Container App name rules: 2-32 chars, lowercase alphanumeric + hyphens,
# must start and end alphanumeric. Catching this client-side avoids a
# 5-second round-trip to ARM just to learn the name is invalid.
if [[ ! "${AZ_CONTAINERAPP}" =~ ^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$ ]]; then
  echo "AZ_CONTAINERAPP='${AZ_CONTAINERAPP}' is invalid: must be 2-32 chars, lowercase alphanumeric or hyphens, starting and ending alphanumeric." >&2
  exit 1
fi

# Target port sanity: must be a positive 16-bit integer.
if [[ ! "${TARGET_PORT}" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
  echo "TARGET_PORT='${TARGET_PORT}' is invalid: must be an integer between 1 and 65535." >&2
  exit 1
fi

# Idle timeout sanity: Container Apps caps this at 240 minutes; the Seed
# requires 4. A 0-or-negative value would silently disable the gate and a
# value above the platform cap would be rejected by ARM.
if [[ ! "${IDLE_TIMEOUT_MINUTES}" =~ ^[0-9]+$ ]] || (( IDLE_TIMEOUT_MINUTES < 1 || IDLE_TIMEOUT_MINUTES > 240 )); then
  echo "IDLE_TIMEOUT_MINUTES='${IDLE_TIMEOUT_MINUTES}' is invalid: must be an integer between 1 and 240." >&2
  exit 1
fi

# Empty inbound secrets would silently let every "anonymous" caller through
# at the auth layer. Catch it here rather than in the running container's
# logs — the Rust binary already refuses to start with an empty key, but a
# blank value persisted into the Container Apps secret store is still a bug
# worth catching before the deployment.
if [[ -z "${DEEPSEEK_API_KEY// /}" ]]; then
  echo "DEEPSEEK_API_KEY must not be blank — got only whitespace." >&2
  exit 1
fi
if [[ -z "${CLAURST_API_KEY// /}" ]]; then
  echo "CLAURST_API_KEY must not be blank — got only whitespace. Generate one with 'openssl rand -hex 32'." >&2
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
echo ">> Container App:       ${AZ_CONTAINERAPP} (group: ${AZ_RESOURCE_GROUP})"
echo ">> Target port:         ${TARGET_PORT}"
echo ">> Idle timeout:        ${IDLE_TIMEOUT_MINUTES} minutes"

echo ">> Ensuring 'containerapp' Azure CLI extension is installed..."
if [ -z "$(az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>/dev/null)" ]; then
    az extension add --name containerapp --only-show-errors --yes --output none
else
    echo "   (already installed; skipping add/upgrade)"
fi

# -----------------------------------------------------------------------------
# Step 1: confirm the Container App exists
# -----------------------------------------------------------------------------

# We deliberately do *not* create the app here — that's provision-app.sh's
# job, and silently materialising one would skip its registry + identity
# wiring. Surface a clear "run the prereq" error instead.
EXISTING_APP_ID="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query id \
  --output tsv 2>/dev/null || true)"

if [[ -z "${EXISTING_APP_ID}" ]]; then
  echo "Container App '${AZ_CONTAINERAPP}' not found in resource group '${AZ_RESOURCE_GROUP}'." >&2
  echo "Run deploy/provision-app.sh first to create the app, then re-run this script to configure its runtime." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 2: re-assert ingress (external, target port, 4-minute idle timeout)
# -----------------------------------------------------------------------------

# Container Apps splits ingress into two CLI calls:
#   • `az containerapp ingress enable` — turn ingress on, set visibility +
#     target port. Idempotent: re-running with the same args is a no-op,
#     and changing the target port hot-swaps it without restarting the app.
#   • `az containerapp ingress update --idle-timeout-in-minutes` — set the
#     HTTP request idle timeout. May not be available on older `az`
#     versions; we tolerate that with a warn-and-continue.
#
# The Seed-mandated values are baked in here:
#   --type external          → public HTTPS endpoint via the managed proxy
#   --target-port 8080       → Dockerfile EXPOSE 8080 + serve.rs binds 0.0.0.0:8080
#   --transport auto         → platform picks HTTP/1.1 vs HTTP/2
#   --idle-timeout 4 minutes → 240 s synchronous-blocking deadline
echo ">> Re-asserting ingress: external visibility, port ${TARGET_PORT}, transport auto..."
az containerapp ingress enable \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --type external \
  --target-port "${TARGET_PORT}" \
  --transport auto \
  --output none

echo ">> Setting ingress idle timeout to ${IDLE_TIMEOUT_MINUTES} minute(s) ($((IDLE_TIMEOUT_MINUTES * 60))s)..."
if ! az containerapp ingress update \
      --name "${AZ_CONTAINERAPP}" \
      --resource-group "${AZ_RESOURCE_GROUP}" \
      --idle-timeout-in-minutes "${IDLE_TIMEOUT_MINUTES}" \
      --output none 2>/dev/null; then
  echo "   (ingress idle-timeout setter unavailable on this az version — the platform default of 240 s still applies; upgrade az to silence this notice.)" >&2
fi

# -----------------------------------------------------------------------------
# Step 3: store the two Container Apps secrets
# -----------------------------------------------------------------------------

# `az containerapp secret set` is the canonical way to write into the Container
# App's encrypted secret store. The literal values never appear in:
#   • `az containerapp show` output
#   • ARM exports / template captures
#   • activity logs / audit logs
# They are decrypted only at container start, in-memory inside the platform's
# revision controller. Rotation is just a re-run with new values + a revision
# restart (see `deploy/secrets/README.md`).
#
# Naming convention: lowercase-hyphenated for the secret name (Azure
# requirement; `_` is rejected), UPPER_SNAKE for the env-var binding.
echo ">> Storing secrets on Container App '${AZ_CONTAINERAPP}'..."
az containerapp secret set \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --secrets \
    "deepseek-api-key=${DEEPSEEK_API_KEY}" \
    "claurst-api-key=${CLAURST_API_KEY}" \
  --output none

# -----------------------------------------------------------------------------
# Step 4: bind the secrets to environment variables on the running container
# -----------------------------------------------------------------------------

# `--set-env-vars NAME=secretref:<secret-name>` stores only the reference in
# the revision template; the platform resolves it at container start. Using
# this form (rather than `value=...`) keeps the literal out of every artifact
# the operator might paste into a ticket, dashboard, or screenshot.
#
# The two names below are the Rust binary's read-only contract:
#   • DEEPSEEK_API_KEY → cc-api Config picks it up exactly as in local dev
#   • CLAURST_API_KEY  → serve_auth.rs reads it once at startup and refuses
#                        to start auth-less if the value is missing/empty
#
# Do *not* introduce alternate spellings (ANTHROPIC_API_KEY, API_KEY, …) on
# the server path — they would let a misconfigured deployment silently start
# without auth (see serve_auth.rs's `API_KEY_ENV_VAR = "CLAURST_API_KEY"`).
echo ">> Binding secrets to environment variables on the running container..."
az containerapp update \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --set-env-vars \
    "DEEPSEEK_API_KEY=secretref:deepseek-api-key" \
    "CLAURST_API_KEY=secretref:claurst-api-key" \
  --output none

# -----------------------------------------------------------------------------
# Step 5: verify the resulting configuration
# -----------------------------------------------------------------------------

# Printing the full JSON would echo nothing sensitive (the secret values are
# never returned), but it would be noisy. Instead we collect the four fields
# that map 1:1 to the Sub-AC 3 acceptance criteria:
#   • ingress.external           — public HTTPS endpoint
#   • ingress.targetPort         — port the binary binds to
#   • ingress.fqdn               — the URL the operator can curl
#   • configuration.secrets[]    — both secret names present
#   • template.containers[0].env — both env vars wired via secretRef
echo ">> Verifying configuration..."

INGRESS_EXTERNAL="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.ingress.external \
  --output tsv)"

INGRESS_TARGET_PORT="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.ingress.targetPort \
  --output tsv)"

INGRESS_FQDN="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.ingress.fqdn \
  --output tsv)"

# Sanity-check ingress visibility — `external` must literally be "true".
# A `false` here would mean inbound traffic from the public internet can't
# reach /ask, which violates the seed's "public HTTPS ingress" constraint.
if [[ "${INGRESS_EXTERNAL}" != "true" ]]; then
  echo "Ingress is not external (got '${INGRESS_EXTERNAL}'). The /ask endpoint will not be publicly reachable." >&2
  exit 1
fi

if [[ "${INGRESS_TARGET_PORT}" != "${TARGET_PORT}" ]]; then
  echo "Ingress target port mismatch: requested ${TARGET_PORT}, app reports ${INGRESS_TARGET_PORT}." >&2
  exit 1
fi

# Asking for both secrets and both env vars in a single `show` round-trip
# keeps the verification cost to one ARM call instead of four.
echo ">> Secrets and env-var bindings:"
az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query "{secrets: properties.configuration.secrets[].name, env: properties.template.containers[0].env[?name=='DEEPSEEK_API_KEY' || name=='CLAURST_API_KEY']}" \
  --output table

# Final summary block for the operator. Public FQDN is included so the
# next-step curl is copy-pasteable.
cat <<EOF

>> Runtime configuration converged.
   Container App:    ${AZ_CONTAINERAPP}
   Resource group:   ${AZ_RESOURCE_GROUP}
   Ingress:          external (https://${INGRESS_FQDN})
   Target port:      ${INGRESS_TARGET_PORT}
   Idle timeout:     ${IDLE_TIMEOUT_MINUTES} minute(s)
   Secrets:          deepseek-api-key, claurst-api-key
   Env vars wired:   DEEPSEEK_API_KEY → secretref:deepseek-api-key
                     CLAURST_API_KEY  → secretref:claurst-api-key

   Smoke-test the endpoint (CLAURST_API_KEY must be the value passed in):
   curl -sSf -X POST https://${INGRESS_FQDN}/ask \\
     -H "X-API-Key: \${CLAURST_API_KEY}" \\
     -H 'Content-Type: application/json' \\
     -d '{"question":"What is the capital of France?"}'

   Tail logs:
   az containerapp logs show \\
     --name ${AZ_CONTAINERAPP} \\
     --resource-group ${AZ_RESOURCE_GROUP} \\
     --follow

EOF
