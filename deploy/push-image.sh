#!/usr/bin/env bash
# push-image.sh — authenticate to ACR and push both tagged claurst-ask images.
#
# Satisfies Sub-AC 50302.2: take the four-tag artefact produced by
# build-image.sh and ship the two ACR-bound tags (`:latest` and the immutable
# `:vMAJOR.MINOR.PATCH`) to the Azure Container Registry that
# provision-acr.sh stood up. Authentication is delegated to acr-login.sh so
# this script is "the push step" rather than "the auth-and-push step" — same
# separation of concerns provision-acr / acr-login / build-image already use.
#
# Why two pushes from one script (and not from build-image.sh):
#   build-image.sh deliberately stays push-free so iterating on the Dockerfile
#   doesn't require ACR creds on every cycle. Once the operator is happy with
#   the local image, this script promotes BOTH ACR-bound tags together. They
#   already share a digest (build-image.sh asserts that); pushing them as a
#   pair keeps the rolling `:latest` and the immutable `:vX.Y.Z` in lock-step
#   in the registry, so a Container App revision pinned to either ref pulls
#   bit-for-bit identical content.
#
# Why we re-run acr-login.sh on every invocation:
#   `az acr login` tokens expire after ~3 hours. Calling the login script as
#   a delegate (rather than asking the operator to remember to run it first)
#   makes a fresh push idempotent: re-run this script any time the previous
#   `docker push` failed with `unauthorized`, and you're back in business
#   without having to consult ACR-AUTH.md. The login script is itself a no-op
#   on a freshly-authenticated session, so the cost is one round-trip to AAD.
#
# Required env vars (or pass via flag — see Usage):
#   ACR_NAME             Globally-unique ACR name from provision-acr.sh,
#                        5-50 alphanumerics, NO `.azurecr.io` suffix.
#                        Example: claurstacr1a2b3c
#
# Optional env vars:
#   IMAGE_VERSION        Versioned tag, MUST match `vMAJOR.MINOR.PATCH`
#                        (default: v0.1.0). Must match the value passed to
#                        build-image.sh — mismatched values would push a tag
#                        that doesn't exist locally and `docker push` would
#                        fail loud, but we catch it client-side first to
#                        surface a clearer error.
#   IMAGE_NAME           Repository name (default: claurst-ask). Override
#                        only if you're testing a fork; do not change in
#                        mainline.
#
#   The service-principal env vars consumed by acr-login.sh are forwarded
#   transparently:
#   AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID
#
# Usage:
#   ACR_NAME=claurstacr1a2b3c ./deploy/push-image.sh
#   ACR_NAME=claurstacr1a2b3c IMAGE_VERSION=v0.2.0 ./deploy/push-image.sh
#
#   # CI flow with a service-principal pre-staged in env vars:
#   ACR_NAME=claurstacr1a2b3c \
#   AZURE_CLIENT_ID=... AZURE_CLIENT_SECRET=... AZURE_TENANT_ID=... \
#   ./deploy/push-image.sh
#
# Idempotent: re-running with the same ACR_NAME + IMAGE_VERSION re-pushes the
# same digest under the same two tags. ACR de-dupes layers content-addressably,
# so repeat pushes only re-upload tag manifests, not blob content.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation (mirrors build-image.sh / acr-login.sh — fail fast client-
# side rather than learn the registry name was malformed deep inside docker).
# -----------------------------------------------------------------------------

: "${ACR_NAME:?ACR_NAME must be set (5-50 alphanumeric chars; no .azurecr.io suffix)}"

if [[ ! "${ACR_NAME}" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
  echo "ACR_NAME='${ACR_NAME}' is invalid: must be 5-50 alphanumeric characters." >&2
  exit 1
fi

IMAGE_VERSION="${IMAGE_VERSION:-v0.1.0}"
IMAGE_NAME="${IMAGE_NAME:-claurst-ask}"

# Same strict semver-with-`v`-prefix that build-image.sh enforces. A mismatch
# between the two scripts (e.g. operator typoed one of them) would manifest
# as a missing local tag below; we catch the typo here with a clearer message.
if [[ ! "${IMAGE_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "IMAGE_VERSION='${IMAGE_VERSION}' is invalid: must match vMAJOR.MINOR.PATCH (e.g. v0.1.0)." >&2
  exit 1
fi

if [[ ! "${IMAGE_NAME}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
  echo "IMAGE_NAME='${IMAGE_NAME}' is invalid: lowercase alphanumeric with -, _, . separators only." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Preflight: docker available, daemon reachable, login script present.
# -----------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on PATH — install Docker Desktop or the docker engine." >&2
  exit 1
fi

# Same daemon-reachability probe as build-image.sh. Without it, the first
# `docker push` would fail with a less-actionable error buried in HTTP output.
if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
  echo "Cannot reach the Docker daemon. Start Docker Desktop / dockerd and retry." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_SCRIPT="${SCRIPT_DIR}/acr-login.sh"

if [[ ! -x "${LOGIN_SCRIPT}" ]]; then
  echo "Expected acr-login.sh next to this script at ${LOGIN_SCRIPT}, but it isn't executable or doesn't exist." >&2
  echo "Run 'chmod +x ${LOGIN_SCRIPT}' or restore the file from version control." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Compute tag set (must match build-image.sh exactly).
# -----------------------------------------------------------------------------

LOGIN_SERVER="${ACR_NAME}.azurecr.io"
ACR_LATEST="${LOGIN_SERVER}/${IMAGE_NAME}:latest"
ACR_VERSION="${LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_VERSION}"

# Verify the two ACR-bound tags actually exist locally before we authenticate
# to the registry. If they don't, the operator skipped build-image.sh (or
# passed mismatched ACR_NAME / IMAGE_VERSION) — better to bail with a clear
# message than burn an `az acr login` round-trip first.
for tag in "${ACR_LATEST}" "${ACR_VERSION}"; do
  if ! docker image inspect --format '{{.Id}}' "${tag}" >/dev/null 2>&1; then
    echo "Local tag '${tag}' not found." >&2
    echo "Run build-image.sh first with the same ACR_NAME and IMAGE_VERSION:" >&2
    echo "  ACR_NAME=${ACR_NAME} IMAGE_VERSION=${IMAGE_VERSION} ./deploy/build-image.sh" >&2
    exit 1
  fi
done

# Both tags should share a digest after build-image.sh; assert that here too
# so a hand-edited `docker tag` between build and push surfaces before we
# upload mismatched content to ACR.
DIGEST_LATEST="$(docker image inspect --format '{{.Id}}' "${ACR_LATEST}")"
DIGEST_VERSION="$(docker image inspect --format '{{.Id}}' "${ACR_VERSION}")"

if [[ "${DIGEST_LATEST}" != "${DIGEST_VERSION}" ]]; then
  echo "Local tags disagree on image digest — refusing to push:" >&2
  echo "  ${ACR_LATEST}  -> ${DIGEST_LATEST}"  >&2
  echo "  ${ACR_VERSION} -> ${DIGEST_VERSION}" >&2
  echo "Re-run build-image.sh to re-tag both refs from the same build." >&2
  exit 1
fi

cat <<EOF
>> Pushing image to ACR:
   Registry: ${LOGIN_SERVER}
   Tags:     ${ACR_LATEST}
             ${ACR_VERSION}
   Digest:   ${DIGEST_LATEST}
EOF

# -----------------------------------------------------------------------------
# Step 1: authenticate to ACR (delegated to acr-login.sh)
# -----------------------------------------------------------------------------

# Forward ACR_NAME and the SP-flow env vars by simply not unsetting them. Bash
# `export` semantics + the `set -u` we already have means a missing required
# var would have failed above; missing optional SP vars just keep the login
# script in interactive (`az login`-already-run) mode.
echo ">> Authenticating to ${LOGIN_SERVER} via acr-login.sh..."
ACR_NAME="${ACR_NAME}" "${LOGIN_SCRIPT}"

# -----------------------------------------------------------------------------
# Step 2: push both tags (same digest, two refs).
# -----------------------------------------------------------------------------

# Push the immutable version FIRST so that if the network drops between the
# two pushes, what's in ACR is the pinned release rather than a `latest` that
# floats. ACR is content-addressable, so the second push only uploads the
# tag manifest (a few hundred bytes) — blobs are deduped server-side.
echo ">> Pushing ${ACR_VERSION}..."
docker push "${ACR_VERSION}"

echo ">> Pushing ${ACR_LATEST}..."
docker push "${ACR_LATEST}"

# -----------------------------------------------------------------------------
# Step 3: verify ACR sees both tags pointing at the same digest.
# -----------------------------------------------------------------------------

# Use `az acr repository show` rather than `docker manifest inspect` because
# the former works without DOCKER_CLI_EXPERIMENTAL=enabled and has consistent
# output across docker / podman / nerdctl. We compare the registry-reported
# manifest digests for the two tags; a mismatch here would mean ACR somehow
# saw two different uploads, which should be impossible given the local
# digest equality we asserted above but is cheap to verify.
echo ">> Verifying both tags resolve to the same manifest in ACR..."

REMOTE_DIGEST_LATEST="$(az acr repository show \
  --name "${ACR_NAME}" \
  --image "${IMAGE_NAME}:latest" \
  --query digest \
  --output tsv)"

REMOTE_DIGEST_VERSION="$(az acr repository show \
  --name "${ACR_NAME}" \
  --image "${IMAGE_NAME}:${IMAGE_VERSION}" \
  --query digest \
  --output tsv)"

if [[ -z "${REMOTE_DIGEST_LATEST}" || -z "${REMOTE_DIGEST_VERSION}" ]]; then
  echo "Could not read manifest digests back from ACR — verify the registry is reachable." >&2
  exit 1
fi

if [[ "${REMOTE_DIGEST_LATEST}" != "${REMOTE_DIGEST_VERSION}" ]]; then
  echo "Remote digest mismatch — ACR shows different content for the two tags:" >&2
  echo "  ${ACR_LATEST}  -> ${REMOTE_DIGEST_LATEST}"  >&2
  echo "  ${ACR_VERSION} -> ${REMOTE_DIGEST_VERSION}" >&2
  echo "Re-run build-image.sh + push-image.sh to recover." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Summary + next-step commands.
# -----------------------------------------------------------------------------

cat <<EOF

>> Push complete. ACR holds both tags at digest ${REMOTE_DIGEST_LATEST}.

   Verify from another machine:
     az acr repository show-tags --name ${ACR_NAME} --repository ${IMAGE_NAME} --output tsv

   Next step:
     # Wire the registry into a Container App revision (next sub-AC).
     # The Container App will pull ${LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_VERSION}
     # using the registry's admin-user credentials configured in deploy/secrets/.

EOF
