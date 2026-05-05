#!/usr/bin/env bash
# build-image.sh — build the claurst-ask container image and tag it for ACR.
#
# Satisfies Sub-AC 50301.1: produce a single `docker build` artefact that
# carries BOTH the rolling `latest` tag AND a versioned tag (e.g. v0.1.0),
# AND mirrors of both onto the provisioned Azure Container Registry's login
# server (<ACR_NAME>.azurecr.io/claurst-ask:<tag>).
#
# Why all four tags from one build:
#   `docker build -t a -t b -t c -t d .` produces a single image manifest
#   and applies all four tags to the same content-addressable digest. That
#   matters because:
#     * `claurst-ask:latest` is the rolling pointer the operator uses for
#       quick local sanity-checks (e.g. `docker run --rm claurst-ask:latest
#       --version`).
#     * `claurst-ask:v0.1.0` is the immutable, releasable tag — once it's in
#       ACR the SHA underneath it must never change.
#     * `<acr>.azurecr.io/claurst-ask:{latest,v0.1.0}` are the push targets
#       the next sub-AC (`docker push`) consumes. Tagging at build time keeps
#       the local image and the registry-bound image bit-for-bit identical
#       without a second `docker tag` step that could drift if the build
#       cache changes between runs.
#
# Why we DON'T push from this script:
#   The seed is explicit that build, push, and Container Apps create are
#   sibling sub-ACs. Keeping push out of this script means the operator can
#   re-run a build cheaply (e.g. iterating on a Dockerfile change) without
#   re-authenticating to ACR or cutting a new release on every iteration.
#   `acr-login.sh` + `docker push` are the next steps; we surface them in
#   the closing summary block.
#
# Required env vars (or pass via flag — see Usage):
#   ACR_NAME             Globally-unique ACR name from provision-acr.sh,
#                        5–50 alphanumerics, NO `.azurecr.io` suffix.
#                        Example: claurstacr1a2b3c
#
# Optional env vars:
#   IMAGE_VERSION        Versioned tag, MUST match `vMAJOR.MINOR.PATCH`
#                        (default: v0.1.0). The leading `v` is mandatory so
#                        the tag sorts correctly in registry browsers and
#                        cannot be confused with a Docker manifest digest.
#   IMAGE_NAME           Repository name (default: claurst-ask). Override
#                        only if you're testing a fork or a side-by-side
#                        deployment; do not change in mainline.
#   DOCKER_BUILDKIT      Defaults to 1 — required for the cache-mount
#                        `RUN --mount=type=cache` lines in the Dockerfile.
#                        Setting this to 0 will still produce a working
#                        image but cold-build time roughly triples.
#   BUILD_CONTEXT        Repo-relative path to the Docker build context.
#                        Defaults to the parent of this script's directory
#                        (i.e. the repo root) — change only if you've moved
#                        the Dockerfile.
#
# Usage:
#   ACR_NAME=claurstacr1a2b3c ./deploy/build-image.sh
#   ACR_NAME=claurstacr1a2b3c IMAGE_VERSION=v0.2.0 ./deploy/build-image.sh
#
# Idempotent: re-running with the same ACR_NAME + IMAGE_VERSION re-tags
# whatever the build produces; BuildKit's cache reuses unchanged layers, so
# a no-op rebuild is fast (seconds, not minutes).

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${ACR_NAME:?ACR_NAME must be set (5-50 alphanumeric chars; no .azurecr.io suffix)}"

# Match the same regex provision-acr.sh / acr-login.sh enforce. Catching this
# client-side avoids burning a `docker build` cycle (potentially minutes) just
# to learn the registry name was malformed at the final `docker tag` step.
if [[ ! "${ACR_NAME}" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
  echo "ACR_NAME='${ACR_NAME}' is invalid: must be 5-50 alphanumeric characters." >&2
  exit 1
fi

IMAGE_VERSION="${IMAGE_VERSION:-v0.1.0}"
IMAGE_NAME="${IMAGE_NAME:-claurst-ask}"

# Strict semver-with-`v`-prefix. The `v` is mandatory because:
#   1. It mirrors the GitHub release-tag convention operators already know.
#   2. It distinguishes the tag from a 12-hex-char Docker manifest digest in
#      logs / `docker images` output, eliminating a class of cut-paste bugs.
# Pre-release / build-metadata suffixes (-rc1, +build.7) are deliberately
# rejected: ACR's runtime image must be a clean release, not a candidate.
if [[ ! "${IMAGE_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "IMAGE_VERSION='${IMAGE_VERSION}' is invalid: must match vMAJOR.MINOR.PATCH (e.g. v0.1.0)." >&2
  exit 1
fi

# Repository names follow Docker's distribution spec: lowercase alphanumeric
# plus `.`, `_`, `-`. No leading separator. Keeping this strict here means we
# never produce an image tag that would be rejected by `docker push` later.
if [[ ! "${IMAGE_NAME}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
  echo "IMAGE_NAME='${IMAGE_NAME}' is invalid: lowercase alphanumeric with -, _, . separators only." >&2
  exit 1
fi

# Resolve the build context relative to this script. `${BASH_SOURCE[0]}` is
# the script path even when sourced or invoked from a different cwd; one
# `dirname` strips the filename, a second strips `deploy/` to land at the
# repo root where the Dockerfile lives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONTEXT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_CONTEXT="${BUILD_CONTEXT:-${DEFAULT_CONTEXT}}"

if [[ ! -f "${BUILD_CONTEXT}/Dockerfile" ]]; then
  echo "Dockerfile not found at ${BUILD_CONTEXT}/Dockerfile" >&2
  echo "Set BUILD_CONTEXT to the directory that contains the Dockerfile." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Preflight: docker available and daemon reachable
# -----------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on PATH — install Docker Desktop or the docker engine." >&2
  exit 1
fi

# `docker info` round-trips to the daemon; if the daemon isn't running it
# fails fast with a clear error. Without this check the build would still
# fail, just with a less-actionable message buried in BuildKit output.
if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
  echo "Cannot reach the Docker daemon. Start Docker Desktop / dockerd and retry." >&2
  exit 1
fi

# BuildKit is required by the Dockerfile's `RUN --mount=type=cache` lines.
# Modern Docker Desktop has it on by default, but `docker engine` on Linux
# may not — exporting the env var here guarantees the build works either way.
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"

# -----------------------------------------------------------------------------
# Compute tag set
# -----------------------------------------------------------------------------

LOGIN_SERVER="${ACR_NAME}.azurecr.io"

# All four refs point at the same image after `docker build -t ... -t ...`:
#   1. local:latest   — quick `docker run` from a developer laptop
#   2. local:vX.Y.Z   — pinned local reference (e.g. for compose files)
#   3. acr:latest     — push target for the rolling production tag
#   4. acr:vX.Y.Z     — push target for the immutable release tag
LOCAL_LATEST="${IMAGE_NAME}:latest"
LOCAL_VERSION="${IMAGE_NAME}:${IMAGE_VERSION}"
ACR_LATEST="${LOGIN_SERVER}/${IMAGE_NAME}:latest"
ACR_VERSION="${LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_VERSION}"

cat <<EOF
>> Building image with tags:
   - ${LOCAL_LATEST}
   - ${LOCAL_VERSION}
   - ${ACR_LATEST}
   - ${ACR_VERSION}
   Build context: ${BUILD_CONTEXT}
   Dockerfile:    ${BUILD_CONTEXT}/Dockerfile
EOF

# -----------------------------------------------------------------------------
# Build (single invocation, four `-t` tags → identical digest for all)
# -----------------------------------------------------------------------------

# `docker build` accepts multiple `-t` flags; every supplied tag is applied to
# the same final image manifest. This is the canonical way to build-and-tag
# atomically — using `docker tag` after the fact would work but introduces a
# (tiny) window where `local:latest` and `acr:latest` diverge.
#
# `--pull` forces BuildKit to refresh the upstream `rust:1.88-slim-bookworm`
# and `debian:bookworm-slim` base images. Without it, a long-lived workstation
# could ship a six-month-old base layer with known CVEs. The cost is one
# round-trip to the registry per base image per build, which is negligible
# next to the Rust compile.
docker build \
  --pull \
  --tag "${LOCAL_LATEST}" \
  --tag "${LOCAL_VERSION}" \
  --tag "${ACR_LATEST}" \
  --tag "${ACR_VERSION}" \
  --file "${BUILD_CONTEXT}/Dockerfile" \
  "${BUILD_CONTEXT}"

# -----------------------------------------------------------------------------
# Verification: confirm the four tags really did land on the same digest
# -----------------------------------------------------------------------------

# `docker image inspect` prints the same Image ID for tags that share a
# manifest. We assert all four match so a future bug (e.g. an accidental
# `docker tag` between `-t` flags) surfaces here, not in production where
# `acr:latest` and `acr:v0.1.0` would silently disagree.
DIGEST_LATEST="$(docker image inspect --format '{{.Id}}' "${LOCAL_LATEST}")"
DIGEST_VERSION="$(docker image inspect --format '{{.Id}}' "${LOCAL_VERSION}")"
DIGEST_ACR_LATEST="$(docker image inspect --format '{{.Id}}' "${ACR_LATEST}")"
DIGEST_ACR_VERSION="$(docker image inspect --format '{{.Id}}' "${ACR_VERSION}")"

if [[ "${DIGEST_LATEST}" != "${DIGEST_VERSION}" \
   || "${DIGEST_LATEST}" != "${DIGEST_ACR_LATEST}" \
   || "${DIGEST_LATEST}" != "${DIGEST_ACR_VERSION}" ]]; then
  echo "Tag-digest mismatch — refusing to proceed." >&2
  echo "  ${LOCAL_LATEST}   -> ${DIGEST_LATEST}"   >&2
  echo "  ${LOCAL_VERSION}  -> ${DIGEST_VERSION}"  >&2
  echo "  ${ACR_LATEST}     -> ${DIGEST_ACR_LATEST}"   >&2
  echo "  ${ACR_VERSION}    -> ${DIGEST_ACR_VERSION}"  >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Summary + next-step commands
# -----------------------------------------------------------------------------

cat <<EOF

>> Build complete. All four tags resolve to image ${DIGEST_LATEST}.

   Next steps:

   # 1. Authenticate to ACR and push both tags in one step:
   ACR_NAME=${ACR_NAME} IMAGE_VERSION=${IMAGE_VERSION} ./deploy/push-image.sh

   # (push-image.sh delegates to acr-login.sh internally — no separate auth step.)

   # Or, if you'd rather drive the lower-level flow yourself:
   ACR_NAME=${ACR_NAME} ./deploy/acr-login.sh   # see deploy/ACR-AUTH.md
   docker push ${ACR_LATEST}
   docker push ${ACR_VERSION}

   # 2. Wire the registry into a Container App revision (next sub-AC).

EOF
