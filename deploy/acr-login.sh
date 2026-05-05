#!/usr/bin/env bash
# acr-login.sh — authenticate the local/CI environment to the provisioned ACR.
#
# Satisfies Sub-AC 3.3: a single, focused script that handles ACR authentication
# for both interactive developer workstations AND headless CI runners, so the
# subsequent `docker push <loginServer>/claurst-ask:<tag>` command from
# provision-acr.sh's "next steps" block actually has credentials to push with.
#
# Why this exists separately from provision-acr.sh:
#   provision-acr.sh runs once when the registry is first stood up; this script
#   runs every time someone (or CI) needs to push a new image. Splitting them
#   keeps the "stand up infra" step idempotent-but-rare and the "push an image"
#   step idempotent-and-cheap.
#
# Two flows are supported:
#
#   1. Local interactive (default):
#      The caller has already done `az login` in their browser. We just refresh
#      Docker's stored credential helper for `<acr>.azurecr.io` via `az acr login`.
#
#   2. CI / headless (when SP_* env vars are present):
#      We log in with a service principal first (non-interactive), then run the
#      same `az acr login`. This is the GitHub Actions / Azure DevOps shape:
#      AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID supplied as
#      pipeline secrets and exported into the job environment.
#
# A third sub-flow — `--token` mode — emits a short-lived ACR access token to
# stdout instead of poking the Docker daemon. This unblocks build environments
# that don't ship Docker (kaniko, buildah, devcontainer-without-DinD), where the
# image build step accepts `--registry-token` directly. It is opt-in to keep
# the default path simple.
#
# Required env vars:
#   ACR_NAME             Registry name (5-50 alphanumerics, no domain suffix).
#                        Example: claurstacr1a2b3c — same value passed to
#                        provision-acr.sh; do NOT include `.azurecr.io`.
#
# Optional env vars:
#   AZURE_CLIENT_ID      Service-principal app ID. Triggers CI flow when set.
#   AZURE_CLIENT_SECRET  Service-principal password. Required iff CLIENT_ID set.
#   AZURE_TENANT_ID      AAD tenant ID. Required iff CLIENT_ID set.
#   ACR_LOGIN_MODE       `docker` (default) | `token`. `token` prints a short-
#                        lived access token to stdout instead of touching Docker;
#                        useful for daemonless build tools.
#
# Usage examples:
#
#   # Local developer (already `az login`'d):
#   ACR_NAME=claurstacr1a2b3c ./deploy/acr-login.sh
#
#   # CI runner with service-principal secrets in env:
#   ACR_NAME=claurstacr1a2b3c \
#   AZURE_CLIENT_ID=...   \
#   AZURE_CLIENT_SECRET=... \
#   AZURE_TENANT_ID=... \
#   ./deploy/acr-login.sh
#
#   # Daemonless builder (kaniko, buildah, etc.) — capture the token:
#   ACR_NAME=claurstacr1a2b3c ACR_LOGIN_MODE=token \
#     ./deploy/acr-login.sh > /tmp/acr-token
#
# Idempotent: re-running refreshes credentials in place; existing Docker creds
# are overwritten with new short-lived tokens (default lifetime ~3 hours).

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${ACR_NAME:?ACR_NAME must be set (5-50 alphanumeric chars; no .azurecr.io suffix)}"

# Match the same regex provision-acr.sh enforces — fail fast client-side rather
# than waiting for ARM to reject a malformed registry name.
if [[ ! "${ACR_NAME}" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
  echo "ACR_NAME='${ACR_NAME}' is invalid: must be 5-50 alphanumeric characters." >&2
  exit 1
fi

ACR_LOGIN_MODE="${ACR_LOGIN_MODE:-docker}"
case "${ACR_LOGIN_MODE}" in
  docker|token) ;;
  *)
    echo "ACR_LOGIN_MODE='${ACR_LOGIN_MODE}' is invalid: expected 'docker' or 'token'." >&2
    exit 1
    ;;
esac

# -----------------------------------------------------------------------------
# Preflight: az CLI present
# -----------------------------------------------------------------------------

if ! command -v az >/dev/null 2>&1; then
  echo "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 1: ensure we have an Azure context
# -----------------------------------------------------------------------------

# Detect whether the caller passed service-principal credentials. We treat the
# trio (CLIENT_ID + CLIENT_SECRET + TENANT_ID) as a unit — any subset is a
# misconfiguration that's better caught here than three commands later.
SP_ID="${AZURE_CLIENT_ID:-}"
SP_SECRET="${AZURE_CLIENT_SECRET:-}"
SP_TENANT="${AZURE_TENANT_ID:-}"

if [[ -n "${SP_ID}" || -n "${SP_SECRET}" || -n "${SP_TENANT}" ]]; then
  if [[ -z "${SP_ID}" || -z "${SP_SECRET}" || -z "${SP_TENANT}" ]]; then
    echo "Service-principal flow requires ALL of AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID." >&2
    exit 1
  fi
  echo ">> Logging in with service principal (CI flow)..."
  # `--service-principal` switches `az login` to non-interactive. Output is
  # silenced because `az login` prints subscription JSON which can include
  # tenant metadata we don't need to leak into CI logs.
  az login \
    --service-principal \
    --username "${SP_ID}" \
    --password "${SP_SECRET}" \
    --tenant "${SP_TENANT}" \
    --output none
else
  # Local interactive flow. We don't auto-run `az login` here — that would open
  # a browser tab on a CI runner and hang forever. Instead, fail loud and tell
  # the operator exactly what to do.
  if ! az account show --output none 2>/dev/null; then
    echo "Not logged in to Azure. Run 'az login' first (interactive), or set" >&2
    echo "AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID for the CI flow." >&2
    exit 1
  fi
fi

SUBSCRIPTION_NAME="$(az account show --query name --output tsv)"
echo ">> Active subscription: ${SUBSCRIPTION_NAME}"
echo ">> Target registry: ${ACR_NAME}.azurecr.io"

# -----------------------------------------------------------------------------
# Step 2: authenticate to the registry
# -----------------------------------------------------------------------------

if [[ "${ACR_LOGIN_MODE}" == "token" ]]; then
  # `--expose-token` does NOT touch the Docker daemon; it returns a JSON blob
  # whose `accessToken` is a short-lived ACR refresh token. Build tools that
  # speak the registry API directly (kaniko, buildah, oras) consume this.
  # Username for token auth is always the literal string `00000000-0000-0000-0000-000000000000`.
  echo ">> Issuing short-lived ACR access token (no Docker daemon required)..."
  az acr login \
    --name "${ACR_NAME}" \
    --expose-token \
    --output tsv \
    --query accessToken
else
  # Default flow: refresh Docker's stored credential helper so subsequent
  # `docker push <loginServer>/...` calls succeed. `az acr login` resolves to
  # `docker login` under the hood with a short-lived token.
  echo ">> Authenticating Docker daemon to ${ACR_NAME}.azurecr.io..."
  az acr login --name "${ACR_NAME}"

  cat <<EOF

>> Authenticated. You can now push images:
   docker push ${ACR_NAME}.azurecr.io/claurst-ask:<tag>

   Token lifetime is ~3 hours; re-run this script to refresh.
EOF
fi
