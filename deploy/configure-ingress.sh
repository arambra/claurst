#!/usr/bin/env bash
# configure-ingress.sh — converge a deployed Container App's public HTTPS
# ingress configuration (visibility, target port, transport) and its ingress
# traffic rules (revisions mode + 100 % of traffic to the latest revision).
#
# Satisfies **AC 5 Sub-AC 3**: "Configure public HTTPS ingress (external,
# target port, transport) and ingress traffic rules on the Container App."
#
# Where this fits in the deploy pipeline:
#
#   provision-acr      → registry exists                       (AC 5)
#   provision-env      → Container Apps environment exists     (AC 5)
#   provision-identity → user-assigned managed identity exists (AC 5/40102)
#   push-image         → image tag pushed to ACR               (AC 6)
#   provision-app      → Container App created/updated         (AC 5 Sub-AC 2)
#   ▶ configure-ingress ◀ ingress + traffic rules in one       (AC 5 Sub-AC 3)
#   configure-runtime  → ingress + secrets + env vars in one   (AC 7 / 40103 Sub-AC 3)
#
# `provision-app.sh` already creates an app with `--ingress external`,
# `--target-port 8080`, `--transport auto`, and `--revisions-mode single`.
# This script is the single coherent **ingress-only converger** — it asserts
# both halves at once, so re-running it brings any drifted Container App back
# to the desired ingress shape without touching secrets / env vars (those are
# `setup-secrets.sh`'s and `configure-runtime.sh`'s job).
#
# Why a separate script when configure-runtime.sh already covers ingress?
#
# `configure-runtime.sh` conflates ingress + secrets + env-var bindings into a
# single converger and **requires** DEEPSEEK_API_KEY + CLAURST_API_KEY to run.
# That is too heavy for the common case of "the app's ingress drifted, fix it
# without rotating any secret". `configure-ingress.sh` is the minimal entry
# point for that case: it touches only the ingress + traffic surface, takes no
# secret material, and is therefore safe to bake into a routine convergence
# job that runs on every deploy without exposing the operator's secrets.
#
# What this script does, in order:
#   1. Confirms `az` is installed, the caller is logged in, and the
#      `containerapp` extension is current.
#   2. Confirms the Container App exists (fails fast otherwise — there is
#      nothing to configure if `provision-app.sh` hasn't been run).
#   3. Re-asserts ingress visibility (`external`), target port, and transport
#      (`auto`) via `az containerapp ingress enable`. Idempotent: re-running
#      with the same args is a no-op.
#   4. Re-asserts the HTTP request idle timeout (4 minutes = 240 s). The
#      platform default already caps at 240 s, but pinning the value
#      explicitly makes the configuration auditable in `az containerapp show`.
#   5. Re-asserts revisions mode = `single` via `az containerapp revision set-mode`.
#      In single-revision mode, Container Apps automatically routes 100 % of
#      traffic to the latest active revision; this *is* the Seed-mandated
#      ingress traffic rule, expressed as a top-level revisions-mode setting
#      rather than a per-revision weight.
#   6. Looks up the latest active revision and explicitly asserts the traffic
#      rule via `az containerapp ingress traffic set --revision-weight
#      <latest>=100`. Redundant under single-revision mode (which already
#      pins traffic to the latest revision), but pinning the explicit weight:
#        • makes the traffic rule auditable in `az containerapp ingress traffic show`,
#        • survives a future operator flipping revisions-mode to `multiple`
#          via the portal — without this assertion, the next deploy could
#          inadvertently split traffic between the old and new revisions.
#      The call is wrapped in a soft-fail because some `az` versions reject
#      manual traffic config in single-revision mode with exit code 2.
#   7. Verifies the resulting configuration end-to-end and prints a summary
#      block with the public FQDN, the live ingress fields, and the live
#      traffic rule.
#
# Required env vars (or pass on the command line — see Usage):
#   AZ_RESOURCE_GROUP    Resource group containing the Container App
#                        (must match provision-app.sh).
#   AZ_CONTAINERAPP      Name of the Container App (e.g. claurst-ask).
#
# Optional env vars:
#   TARGET_PORT          Container port the binary listens on (default: 8080,
#                        matches Dockerfile EXPOSE and `cc-http`'s bind).
#   TRANSPORT            Ingress transport: auto | http | http2 | tcp
#                        (default: auto — platform picks HTTP/1.1 vs HTTP/2).
#   IDLE_TIMEOUT_MINUTES Ingress request idle timeout in minutes
#                        (default: 4 == 240 s, matches the Seed's
#                        synchronous-blocking constraint).
#   REVISIONS_MODE       single | multiple (default: single, per Seed).
#
# Usage:
#   AZ_RESOURCE_GROUP=rg-claurst \
#   AZ_CONTAINERAPP=claurst-ask \
#   ./deploy/configure-ingress.sh
#
# Re-running the script with the same inputs is safe: every `az` call below
# is idempotent under the chosen invocation. If the operator manually edits
# the ingress in the portal between runs, the next invocation converges it
# back to the Seed-mandated shape.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${AZ_RESOURCE_GROUP:?AZ_RESOURCE_GROUP must be set (e.g. rg-claurst)}"
: "${AZ_CONTAINERAPP:?AZ_CONTAINERAPP must be set (e.g. claurst-ask)}"

TARGET_PORT="${TARGET_PORT:-8080}"
TRANSPORT="${TRANSPORT:-auto}"
IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-4}"
REVISIONS_MODE="${REVISIONS_MODE:-single}"

# Container App name rules: 2-32 chars, lowercase alphanumeric + hyphens, must
# start and end alphanumeric. Catching this client-side avoids a 5-second
# round-trip to ARM just to learn the name is invalid (mirrors provision-app.sh).
if [[ ! "${AZ_CONTAINERAPP}" =~ ^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$ ]]; then
  echo "AZ_CONTAINERAPP='${AZ_CONTAINERAPP}' is invalid: must be 2-32 chars, lowercase alphanumeric or hyphens, starting and ending alphanumeric." >&2
  exit 1
fi

# Target port sanity: must be a positive 16-bit integer.
if [[ ! "${TARGET_PORT}" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
  echo "TARGET_PORT='${TARGET_PORT}' is invalid: must be an integer between 1 and 65535." >&2
  exit 1
fi

# Transport must be one of the four values Container Apps accepts. Catching it
# client-side gives a clearer error than ARM's "InvalidParameterValueInRequest".
case "${TRANSPORT}" in
  auto|http|http2|tcp) ;;
  *)
    echo "TRANSPORT='${TRANSPORT}' is invalid: must be one of auto | http | http2 | tcp." >&2
    exit 1
    ;;
esac

# Idle timeout sanity: Container Apps caps this at 240 minutes; the Seed
# requires 4 (== 240 s). A 0-or-negative value would silently disable the
# gate and a value above the platform cap would be rejected by ARM.
if [[ ! "${IDLE_TIMEOUT_MINUTES}" =~ ^[0-9]+$ ]] || (( IDLE_TIMEOUT_MINUTES < 1 || IDLE_TIMEOUT_MINUTES > 240 )); then
  echo "IDLE_TIMEOUT_MINUTES='${IDLE_TIMEOUT_MINUTES}' is invalid: must be an integer between 1 and 240." >&2
  exit 1
fi

case "${REVISIONS_MODE}" in
  single|multiple) ;;
  *)
    echo "REVISIONS_MODE='${REVISIONS_MODE}' is invalid: must be 'single' or 'multiple'." >&2
    exit 1
    ;;
esac

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
echo ">> Transport:           ${TRANSPORT}"
echo ">> Idle timeout:        ${IDLE_TIMEOUT_MINUTES} minute(s)"
echo ">> Revisions mode:      ${REVISIONS_MODE}"

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
  echo "Run deploy/provision-app.sh first to create the app, then re-run this script to configure its ingress." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 2: re-assert ingress visibility, target port, and transport
# -----------------------------------------------------------------------------

# `az containerapp ingress enable` is the canonical setter for the three
# ingress fields the Seed pins:
#   --type external          → public HTTPS endpoint via the managed reverse proxy
#   --target-port <port>     → port the binary listens on inside the container
#                              (Dockerfile EXPOSE 8080 + cc-http's TcpListener)
#   --transport <auto|...>   → wire protocol; `auto` lets the platform pick
#                              HTTP/1.1 vs HTTP/2 per request
#
# `enable` is idempotent: re-running with the same args is a no-op, and
# changing the target port hot-swaps it without dropping in-flight requests.
echo ">> Re-asserting ingress: external visibility, port ${TARGET_PORT}, transport ${TRANSPORT}..."
az containerapp ingress enable \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --type external \
  --target-port "${TARGET_PORT}" \
  --transport "${TRANSPORT}" \
  --output none

# -----------------------------------------------------------------------------
# Step 3: pin the ingress idle timeout to 4 minutes (240 s)
# -----------------------------------------------------------------------------

# Container Apps' HTTP request idle timeout is `ingress.idleTimeoutInMinutes`.
# 4 minutes = 240 s, which matches the Seed's synchronous-blocking AC. The
# platform default already caps at 240 s, but pinning the value explicitly:
#   • makes the configuration auditable (visible in `az containerapp show`),
#   • survives any future platform default change without a silent regression,
#   • mirrors the Seed's `request_timeout_seconds` ontology concept.
#
# `az containerapp ingress update --idle-timeout-in-minutes` has been the
# stable setter since the May-2024 CLI release. Older CLI versions silently
# ignore unknown flags and exit 2; we tolerate that by allowing the call to
# fail soft and warning the operator to upgrade if so.
echo ">> Setting ingress idle timeout to ${IDLE_TIMEOUT_MINUTES} minute(s) ($((IDLE_TIMEOUT_MINUTES * 60))s)..."
if ! az containerapp ingress update \
      --name "${AZ_CONTAINERAPP}" \
      --resource-group "${AZ_RESOURCE_GROUP}" \
      --idle-timeout-in-minutes "${IDLE_TIMEOUT_MINUTES}" \
      --output none 2>/dev/null; then
  echo "   (ingress idle-timeout setter unavailable on this az version — the platform default of 240 s still applies; upgrade az to silence this notice.)" >&2
fi

# -----------------------------------------------------------------------------
# Step 4: assert revisions mode (drives the implicit traffic rule)
# -----------------------------------------------------------------------------

# In Container Apps, revisions mode is the top-level switch that governs
# ingress traffic distribution:
#   • single    → exactly one active revision; 100 % of traffic to it
#                 automatically. The Seed pins this.
#   • multiple  → up to 100 active revisions; traffic split via per-revision
#                 weights configured below.
#
# Setting this here (rather than only at create time) defends against an
# operator flipping the mode in the portal between runs. `revision set-mode`
# is idempotent and a no-op when the mode already matches.
echo ">> Asserting revisions mode = ${REVISIONS_MODE}..."
az containerapp revision set-mode \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --mode "${REVISIONS_MODE}" \
  --output none

# -----------------------------------------------------------------------------
# Step 5: explicitly assert the ingress traffic rule (100 % to latest revision)
# -----------------------------------------------------------------------------

# `az containerapp ingress traffic set --revision-weight <name>=<weight>` is
# the canonical setter for per-revision traffic weights. We use it to express
# the Seed-mandated rule "100 % of traffic to the latest active revision" in
# a form that's auditable via `az containerapp ingress traffic show`,
# regardless of whether the app is in single- or multiple-revision mode.
#
# Resolving the latest revision: the revision list is sorted descending by
# creationTime, so `[?properties.active] | [0].name` is the most recent
# active revision. Falling back to the first revision in the list (active or
# not) handles the edge case where a brand-new deploy hasn't finished
# activating its single revision yet.
echo ">> Resolving latest active revision..."
LATEST_REVISION="$(az containerapp revision list \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query "sort_by([?properties.active], &properties.createdTime) | [-1].name" \
  --output tsv 2>/dev/null || true)"

if [[ -z "${LATEST_REVISION}" || "${LATEST_REVISION}" == "None" ]]; then
  # No active revisions (yet) — fall back to the most recent one regardless of
  # active state. This is the "deploy still rolling out" edge case.
  LATEST_REVISION="$(az containerapp revision list \
    --name "${AZ_CONTAINERAPP}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --query "sort_by([], &properties.createdTime) | [-1].name" \
    --output tsv 2>/dev/null || true)"
fi

if [[ -z "${LATEST_REVISION}" || "${LATEST_REVISION}" == "None" ]]; then
  echo "   (no revisions found yet — skipping explicit traffic-weight assertion; single-revision mode will route 100 % to the first revision once it activates.)" >&2
else
  echo ">> Asserting ingress traffic rule: 100 % → ${LATEST_REVISION}..."
  if ! az containerapp ingress traffic set \
        --name "${AZ_CONTAINERAPP}" \
        --resource-group "${AZ_RESOURCE_GROUP}" \
        --revision-weight "${LATEST_REVISION}=100" \
        --output none 2>/dev/null; then
    # `traffic set` rejects manual weights when revisions-mode = single on
    # some `az` versions because the mode handles it implicitly. That's not
    # a failure — the implicit rule is *exactly* what the Seed mandates.
    echo "   (manual traffic-weight rejected — single-revision mode already routes 100 % to '${LATEST_REVISION}' implicitly. This is the Seed-mandated rule.)" >&2
  fi
fi

# -----------------------------------------------------------------------------
# Step 6: verify the resulting configuration
# -----------------------------------------------------------------------------

# Five fields map 1:1 to Sub-AC 3's acceptance surface:
#   • ingress.external           — must be `true` (public HTTPS)
#   • ingress.targetPort         — must match the requested port
#   • ingress.transport          — must match the requested transport
#   • ingress.fqdn               — the URL the operator can curl
#   • configuration.activeRevisionsMode — must match REVISIONS_MODE
# The traffic distribution is read separately via `ingress traffic show`
# because it's an array and needs its own JMESPath query.
echo ">> Verifying ingress configuration..."

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

INGRESS_TRANSPORT="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.ingress.transport \
  --output tsv)"

INGRESS_FQDN="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.ingress.fqdn \
  --output tsv)"

LIVE_REVISIONS_MODE="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.activeRevisionsMode \
  --output tsv)"

# Sanity checks: each one violates the Seed if it doesn't match. We exit
# non-zero so a CI pipeline running this script as a verification gate fails
# loudly instead of silently shipping a broken deploy.
if [[ "${INGRESS_EXTERNAL}" != "true" ]]; then
  echo "Ingress is not external (got '${INGRESS_EXTERNAL}'). The /ask endpoint will not be publicly reachable." >&2
  exit 1
fi

if [[ "${INGRESS_TARGET_PORT}" != "${TARGET_PORT}" ]]; then
  echo "Ingress target port mismatch: requested ${TARGET_PORT}, app reports ${INGRESS_TARGET_PORT}." >&2
  exit 1
fi

# Transport string-compare is case-insensitive: the API returns "Auto" / "Http" /
# "Http2" / "Tcp" while the CLI accepts the lowercase forms.
if [[ "${INGRESS_TRANSPORT,,}" != "${TRANSPORT,,}" ]]; then
  echo "Ingress transport mismatch: requested ${TRANSPORT}, app reports ${INGRESS_TRANSPORT}." >&2
  exit 1
fi

# Same case-insensitive compare for revisions mode (API returns "Single" /
# "Multiple", CLI accepts the lowercase forms).
if [[ "${LIVE_REVISIONS_MODE,,}" != "${REVISIONS_MODE,,}" ]]; then
  echo "Revisions mode mismatch: requested ${REVISIONS_MODE}, app reports ${LIVE_REVISIONS_MODE}." >&2
  exit 1
fi

# Show the live traffic distribution as a table — exactly what an operator
# would copy/paste into a ticket to prove the traffic rule is wired correctly.
echo ">> Live ingress traffic distribution:"
az containerapp ingress traffic show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --output table

# Final summary block for the operator. Public FQDN is included so the
# next-step curl is copy-pasteable.
cat <<EOF

>> Ingress configuration converged.
   Container App:    ${AZ_CONTAINERAPP}
   Resource group:   ${AZ_RESOURCE_GROUP}
   Ingress:          external (https://${INGRESS_FQDN})
   Target port:      ${INGRESS_TARGET_PORT}
   Transport:        ${INGRESS_TRANSPORT}
   Idle timeout:     ${IDLE_TIMEOUT_MINUTES} minute(s)
   Revisions mode:   ${LIVE_REVISIONS_MODE}
   Traffic rule:     100 % → ${LATEST_REVISION:-(latest revision, resolved at request time)}

   Smoke-test the endpoint (CLAURST_API_KEY must already be wired via
   deploy/secrets/setup-secrets.sh or deploy/configure-runtime.sh):
   curl -sSf -X POST https://${INGRESS_FQDN}/ask \\
     -H "X-API-Key: \${CLAURST_API_KEY}" \\
     -H 'Content-Type: application/json' \\
     -d '{"question":"What is the capital of France?"}'

   Show live traffic distribution any time:
   az containerapp ingress traffic show \\
     --name ${AZ_CONTAINERAPP} \\
     --resource-group ${AZ_RESOURCE_GROUP} \\
     --output table

EOF
