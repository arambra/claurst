#!/usr/bin/env bash
# verify-image.sh — confirm the pushed claurst-ask manifest is retrievable in ACR.
#
# Satisfies Sub-AC 50303.3: after build-image.sh + push-image.sh have produced
# and uploaded both ACR-bound tags (`:latest` and the immutable
# `:vMAJOR.MINOR.PATCH`), independently verify that the registry actually
# returns each tag's manifest AND that both names appear in its tag listing.
#
# Why this exists separately from push-image.sh:
#   push-image.sh does an inline `az acr repository show --image` check on the
#   tags it just uploaded, but that's coupled to the push flow — it can only
#   prove "the upload I just did is reachable from the host that did the
#   upload, while its `az acr login` token is still warm". This script is the
#   "verify from another machine, days later, with only `az login`" step:
#     * It DOES NOT need Docker — it talks to ACR's data plane via `az` only.
#     * It DOES NOT push or modify state — purely read-only.
#     * It uses BOTH `az acr repository show` (manifest digest per tag) AND
#       `az acr repository show-tags` (registry's authoritative tag listing),
#       so it catches the failure mode where a tag was reachable by digest at
#       push time but never made it into the listing the Container App sees.
#
# Required env vars (or pass via flag — see Usage):
#   ACR_NAME             Globally-unique ACR name from provision-acr.sh,
#                        5-50 alphanumerics, NO `.azurecr.io` suffix.
#                        Example: claurstacr1a2b3c
#
# Optional env vars:
#   IMAGE_VERSION        Versioned tag we expect to see, MUST match
#                        `vMAJOR.MINOR.PATCH` (default: v0.1.0). Match the
#                        value passed to build-image.sh / push-image.sh — a
#                        mismatch surfaces here as a clear "expected tag
#                        not in registry listing" error rather than a silent
#                        deploy of the wrong revision.
#   IMAGE_NAME           Repository name (default: claurst-ask). Override
#                        only if you're testing a fork.
#
# Usage:
#   ACR_NAME=claurstacr1a2b3c ./deploy/verify-image.sh
#   ACR_NAME=claurstacr1a2b3c IMAGE_VERSION=v0.2.0 ./deploy/verify-image.sh
#
# Exit status:
#   0   both tags retrievable, both appear in the tag listing, digests agree
#   1   any of: registry unreachable, repository missing, either tag missing,
#       digests disagree, malformed input
#
# Idempotent + read-only: re-runnable as a smoke test from CI, a release-
# verification step, or a post-deploy sanity check.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation — same regex contract every other deploy script enforces,
# kept identical so a typo here matches the typo error message there.
# -----------------------------------------------------------------------------

: "${ACR_NAME:?ACR_NAME must be set (5-50 alphanumeric chars; no .azurecr.io suffix)}"

if [[ ! "${ACR_NAME}" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
  echo "ACR_NAME='${ACR_NAME}' is invalid: must be 5-50 alphanumeric characters." >&2
  exit 1
fi

IMAGE_VERSION="${IMAGE_VERSION:-v0.1.0}"
IMAGE_NAME="${IMAGE_NAME:-claurst-ask}"

if [[ ! "${IMAGE_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "IMAGE_VERSION='${IMAGE_VERSION}' is invalid: must match vMAJOR.MINOR.PATCH (e.g. v0.1.0)." >&2
  exit 1
fi

if [[ ! "${IMAGE_NAME}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
  echo "IMAGE_NAME='${IMAGE_NAME}' is invalid: lowercase alphanumeric with -, _, . separators only." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Preflight: az CLI present and a session is active.
# -----------------------------------------------------------------------------

if ! command -v az >/dev/null 2>&1; then
  echo "az not found on PATH — install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
  exit 1
fi

# `az account show` is the cheapest "are we logged in?" probe and works for
# both interactive `az login` and service-principal sessions. We don't need
# the output, only the exit code.
if ! az account show --output none 2>/dev/null; then
  echo "No active Azure CLI session. Run 'az login' (interactive) or set up a service principal first." >&2
  echo "For CI: AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID via 'az login --service-principal'." >&2
  exit 1
fi

LOGIN_SERVER="${ACR_NAME}.azurecr.io"
EXPECTED_LATEST="latest"
EXPECTED_VERSION="${IMAGE_VERSION}"

cat <<EOF
>> Verifying ACR manifest:
   Registry:    ${LOGIN_SERVER}
   Repository:  ${IMAGE_NAME}
   Expected tags:
     - ${EXPECTED_LATEST}
     - ${EXPECTED_VERSION}
EOF

# -----------------------------------------------------------------------------
# Step 1: confirm the repository exists at all.
#
# `az acr repository show --repository <name>` returns repo-level metadata
# (manifest count, last-updated-time, etc.). A missing repo here means the
# push never landed — fail with a message pointing back at push-image.sh
# rather than letting the per-tag lookups below produce noisier errors.
# -----------------------------------------------------------------------------

echo ""
echo ">> [1/4] az acr repository show --repository ${IMAGE_NAME}"

if ! REPO_INFO="$(az acr repository show \
  --name "${ACR_NAME}" \
  --repository "${IMAGE_NAME}" \
  --output json 2>&1)"; then
  echo "Repository '${IMAGE_NAME}' not found in registry '${ACR_NAME}'." >&2
  echo "Has push-image.sh been run for this ACR? See its output for the expected tags." >&2
  echo "az error:" >&2
  echo "${REPO_INFO}" >&2
  exit 1
fi

echo "${REPO_INFO}"

# -----------------------------------------------------------------------------
# Step 2: list all tags and confirm both expected names are present.
#
# `show-tags` is the authoritative answer to "what does ACR think exists in
# this repo?". A tag can be unreachable via `--image` lookup briefly during
# replication; the listing is the steady-state truth a Container App will
# resolve against. We do this BEFORE the per-tag `show` calls so a missing
# tag surfaces as "expected tag not in listing" (the actionable failure)
# rather than "manifest fetch failed" (which doesn't tell the operator
# whether the tag was ever pushed or just briefly unreachable).
# -----------------------------------------------------------------------------

echo ""
echo ">> [2/4] az acr repository show-tags --repository ${IMAGE_NAME}"

if ! TAGS_TSV="$(az acr repository show-tags \
  --name "${ACR_NAME}" \
  --repository "${IMAGE_NAME}" \
  --output tsv 2>&1)"; then
  echo "Could not list tags for ${LOGIN_SERVER}/${IMAGE_NAME}." >&2
  echo "az error:" >&2
  echo "${TAGS_TSV}" >&2
  exit 1
fi

if [[ -z "${TAGS_TSV}" ]]; then
  echo "Tag listing for ${IMAGE_NAME} is empty — repository exists but holds no tags." >&2
  echo "Run push-image.sh to upload ${EXPECTED_LATEST} and ${EXPECTED_VERSION}." >&2
  exit 1
fi

# Print the listing for the operator's records — useful when this script is
# being run as a release-gate by hand and the human wants to eyeball it.
echo "${TAGS_TSV}"

# Use grep with -Fx (fixed-string, full-line) to avoid false positives where
# an unrelated tag like `v0.1.0-rc1` would substring-match `v0.1.0`. -q keeps
# the script quiet; the next echo gives the human-readable verdict.
missing_tags=()
for expected in "${EXPECTED_LATEST}" "${EXPECTED_VERSION}"; do
  if ! grep -Fxq "${expected}" <<<"${TAGS_TSV}"; then
    missing_tags+=("${expected}")
  fi
done

if (( ${#missing_tags[@]} > 0 )); then
  echo "" >&2
  echo "Tag listing is missing expected tag(s): ${missing_tags[*]}" >&2
  echo "Run push-image.sh with the same ACR_NAME and IMAGE_VERSION to upload them." >&2
  exit 1
fi

echo ""
echo "   Both expected tags present in registry listing."

# -----------------------------------------------------------------------------
# Step 3: per-tag manifest lookup via `az acr repository show --image`.
#
# This is the read every Container App revision will perform when it pulls;
# if it fails here it will fail at deploy time. We capture the manifest
# digest so step 4 can assert tag-pair coherence.
# -----------------------------------------------------------------------------

echo ""
echo ">> [3/4] az acr repository show --image ${IMAGE_NAME}:<tag>"

if ! DIGEST_LATEST="$(az acr repository show \
  --name "${ACR_NAME}" \
  --image "${IMAGE_NAME}:${EXPECTED_LATEST}" \
  --query digest \
  --output tsv 2>&1)"; then
  echo "Could not retrieve manifest for ${LOGIN_SERVER}/${IMAGE_NAME}:${EXPECTED_LATEST}." >&2
  echo "az error:" >&2
  echo "${DIGEST_LATEST}" >&2
  exit 1
fi

if ! DIGEST_VERSION="$(az acr repository show \
  --name "${ACR_NAME}" \
  --image "${IMAGE_NAME}:${EXPECTED_VERSION}" \
  --query digest \
  --output tsv 2>&1)"; then
  echo "Could not retrieve manifest for ${LOGIN_SERVER}/${IMAGE_NAME}:${EXPECTED_VERSION}." >&2
  echo "az error:" >&2
  echo "${DIGEST_VERSION}" >&2
  exit 1
fi

DIGEST_LATEST="$(printf '%s' "${DIGEST_LATEST}" | tr -d '[:space:]')"
DIGEST_VERSION="$(printf '%s' "${DIGEST_VERSION}" | tr -d '[:space:]')"

if [[ -z "${DIGEST_LATEST}" || -z "${DIGEST_VERSION}" ]]; then
  echo "Manifest digest came back empty for one or both tags." >&2
  echo "  ${EXPECTED_LATEST}  -> '${DIGEST_LATEST}'"  >&2
  echo "  ${EXPECTED_VERSION} -> '${DIGEST_VERSION}'" >&2
  exit 1
fi

echo "   ${IMAGE_NAME}:${EXPECTED_LATEST}  -> ${DIGEST_LATEST}"
echo "   ${IMAGE_NAME}:${EXPECTED_VERSION} -> ${DIGEST_VERSION}"

# -----------------------------------------------------------------------------
# Step 4: assert both tags resolve to the same manifest.
#
# build-image.sh + push-image.sh guarantee bit-for-bit equality at upload;
# checking it here closes the loop in case a third party (e.g. a CI job
# pinning `:latest` to a different release) snuck a divergent push between
# our build and our verify. This is the failure mode that would silently
# deploy `:vX.Y.Z` while shipping a different `:latest` to anyone pinning
# the rolling tag.
# -----------------------------------------------------------------------------

echo ""
echo ">> [4/4] Tag-pair coherence check"

if [[ "${DIGEST_LATEST}" != "${DIGEST_VERSION}" ]]; then
  echo "Remote digest mismatch — tags resolve to different content:" >&2
  echo "  ${IMAGE_NAME}:${EXPECTED_LATEST}  -> ${DIGEST_LATEST}"  >&2
  echo "  ${IMAGE_NAME}:${EXPECTED_VERSION} -> ${DIGEST_VERSION}" >&2
  echo "Re-run build-image.sh + push-image.sh from a clean checkout to recover." >&2
  exit 1
fi

echo "   Both tags resolve to the same manifest digest."

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

cat <<EOF

>> Verification PASSED.
   ${LOGIN_SERVER}/${IMAGE_NAME} holds ${EXPECTED_LATEST} and ${EXPECTED_VERSION}
   at digest ${DIGEST_LATEST}.

   Pin a Container App revision to the immutable tag for production:
     ${LOGIN_SERVER}/${IMAGE_NAME}:${EXPECTED_VERSION}
EOF
