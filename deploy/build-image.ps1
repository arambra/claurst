# build-image.ps1 — build the claurst-ask container image and tag it for ACR.
#
# PowerShell 7+ counterpart to build-image.sh. Satisfies Sub-AC 50301.1:
# produce a single `docker build` artefact that carries BOTH the rolling
# `latest` tag AND a versioned tag (e.g. v0.1.0), AND mirrors of both onto
# the provisioned Azure Container Registry's login server
# (<AcrName>.azurecr.io/claurst-ask:<tag>).
#
# Why all four tags from one build:
#   `docker build -t a -t b -t c -t d .` produces a single image manifest
#   and applies all four tags to the same content-addressable digest. That
#   matters because:
#     * `claurst-ask:latest` is the rolling pointer the operator uses for
#       quick local sanity-checks (e.g. `docker run --rm claurst-ask:latest
#       --version`).
#     * `claurst-ask:v0.1.0` is the immutable, releasable tag — once it's
#       in ACR the SHA underneath it must never change.
#     * `<acr>.azurecr.io/claurst-ask:{latest,v0.1.0}` are the push targets
#       the next sub-AC (`docker push`) consumes. Tagging at build time
#       keeps the local image and the registry-bound image bit-for-bit
#       identical without a second `docker tag` step that could drift if
#       the build cache changes between runs.
#
# Why we DON'T push from this script:
#   The seed is explicit that build, push, and Container Apps create are
#   sibling sub-ACs. Keeping push out of this script means the operator
#   can re-run a build cheaply (e.g. iterating on a Dockerfile change)
#   without re-authenticating to ACR or cutting a new release on every
#   iteration. `acr-login.ps1` + `docker push` are the next steps; we
#   surface them in the closing summary block.
#
# Required parameters / env:
#   -AcrName             Globally-unique ACR name from provision-acr.ps1,
#                        5-50 alphanumerics, NO `.azurecr.io` suffix.
#                        Example: claurstacr1a2b3c
#
# Optional:
#   -ImageVersion        Versioned tag, MUST match `vMAJOR.MINOR.PATCH`
#                        (default: v0.1.0). The leading `v` is mandatory
#                        so the tag sorts correctly in registry browsers
#                        and cannot be confused with a manifest digest.
#   -ImageName           Repository name (default: claurst-ask). Override
#                        only if you're testing a fork or a side-by-side
#                        deployment; do not change in mainline.
#   -BuildContext        Path to the Docker build context. Defaults to the
#                        parent of this script's directory (i.e. the repo
#                        root) — change only if you've moved the Dockerfile.
#
# Examples:
#   ./deploy/build-image.ps1 -AcrName claurstacr1a2b3c
#   ./deploy/build-image.ps1 -AcrName claurstacr1a2b3c -ImageVersion v0.2.0
#
# Idempotent: re-running with the same -AcrName + -ImageVersion re-tags
# whatever the build produces; BuildKit's cache reuses unchanged layers,
# so a no-op rebuild is fast (seconds, not minutes).

[CmdletBinding()]
param(
    # Mirrors the Bicep @minLength/@maxLength constraints and ACR's
    # alphanumeric-only rule, matching provision-acr.ps1 / acr-login.ps1.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9]{5,50}$')]
    [string] $AcrName,

    # Strict semver-with-v-prefix. The leading `v` is mandatory because:
    #   1. It mirrors the GitHub release-tag convention.
    #   2. It distinguishes the tag from a 12-hex-char Docker manifest
    #      digest in `docker images` output.
    # Pre-release / build-metadata suffixes (-rc1, +build.7) are
    # deliberately rejected: ACR's runtime image must be a clean release.
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $ImageVersion = 'v0.1.0',

    # Docker repository names follow the distribution spec: lowercase
    # alphanumeric plus `.`, `_`, `-`. Keeping this strict here means we
    # never produce an image tag that would be rejected by `docker push`.
    [ValidatePattern('^[a-z0-9]+([._-][a-z0-9]+)*$')]
    [string] $ImageName = 'claurst-ask',

    [string] $BuildContext
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Resolve build context
# -----------------------------------------------------------------------------

# Default the build context to the repo root (parent of this script's dir).
# `$PSScriptRoot` is the directory the script lives in even when invoked from
# a different cwd; one `Split-Path` call up from there lands at the repo root
# where the Dockerfile sits.
if ([string]::IsNullOrEmpty($BuildContext)) {
    $BuildContext = Split-Path -Parent $PSScriptRoot
}

$dockerfilePath = Join-Path $BuildContext 'Dockerfile'
if (-not (Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
    throw "Dockerfile not found at $dockerfilePath. Pass -BuildContext to point at the directory that contains the Dockerfile."
}

# -----------------------------------------------------------------------------
# Preflight: docker available and daemon reachable
# -----------------------------------------------------------------------------

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found on PATH — install Docker Desktop or the docker engine."
}

# `docker info` round-trips to the daemon; if the daemon isn't running it
# fails fast with a clear error. Without this check the build would still
# fail, just with a less-actionable message buried in BuildKit output.
$null = docker info --format '{{.ServerVersion}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Cannot reach the Docker daemon. Start Docker Desktop / dockerd and retry."
}

# BuildKit is required by the Dockerfile's `RUN --mount=type=cache` lines.
# Modern Docker Desktop has it on by default, but a stripped-down `docker
# engine` install on Linux may not — exporting the env var here guarantees
# the build works either way without surprising the operator.
if (-not $env:DOCKER_BUILDKIT) {
    $env:DOCKER_BUILDKIT = '1'
}

# -----------------------------------------------------------------------------
# Compute tag set
# -----------------------------------------------------------------------------

$loginServer  = "$AcrName.azurecr.io"

# All four refs point at the same image after `docker build -t ... -t ...`:
#   1. local:latest   — quick `docker run` from a developer laptop
#   2. local:vX.Y.Z   — pinned local reference (e.g. for compose files)
#   3. acr:latest     — push target for the rolling production tag
#   4. acr:vX.Y.Z     — push target for the immutable release tag
$localLatest  = "${ImageName}:latest"
$localVersion = "${ImageName}:${ImageVersion}"
$acrLatest    = "$loginServer/${ImageName}:latest"
$acrVersion   = "$loginServer/${ImageName}:${ImageVersion}"

Write-Host ">> Building image with tags:"
Write-Host "   - $localLatest"
Write-Host "   - $localVersion"
Write-Host "   - $acrLatest"
Write-Host "   - $acrVersion"
Write-Host "   Build context: $BuildContext"
Write-Host "   Dockerfile:    $dockerfilePath"

# -----------------------------------------------------------------------------
# Build (single invocation, four `-t` tags -> identical digest for all)
# -----------------------------------------------------------------------------

# `docker build` accepts multiple `--tag` flags; every supplied tag is applied
# to the same final image manifest. This is the canonical way to build-and-tag
# atomically — using `docker tag` after the fact would work but introduces a
# (tiny) window where `local:latest` and `acr:latest` diverge.
#
# `--pull` forces BuildKit to refresh the upstream `rust:1.88-slim-bookworm`
# and `debian:bookworm-slim` base images. Without it, a long-lived workstation
# could ship a six-month-old base layer with known CVEs. Cost is one round-
# trip per base image per build, negligible vs the Rust compile.
docker build `
    --pull `
    --tag $localLatest `
    --tag $localVersion `
    --tag $acrLatest `
    --tag $acrVersion `
    --file $dockerfilePath `
    $BuildContext
if ($LASTEXITCODE -ne 0) {
    throw "docker build failed (exit $LASTEXITCODE)"
}

# -----------------------------------------------------------------------------
# Verification: confirm the four tags really did land on the same digest
# -----------------------------------------------------------------------------

# `docker image inspect` prints the same Image ID for tags that share a
# manifest. We assert all four match so a future bug (e.g. an accidental
# `docker tag` between `-t` flags) surfaces here, not in production where
# `acr:latest` and `acr:v0.1.0` would silently disagree.
$digestLatest    = (docker image inspect --format '{{.Id}}' $localLatest).Trim()
$digestVersion   = (docker image inspect --format '{{.Id}}' $localVersion).Trim()
$digestAcrLatest = (docker image inspect --format '{{.Id}}' $acrLatest).Trim()
$digestAcrVer    = (docker image inspect --format '{{.Id}}' $acrVersion).Trim()

if ($digestLatest -ne $digestVersion -or
    $digestLatest -ne $digestAcrLatest -or
    $digestLatest -ne $digestAcrVer) {
    Write-Host "Tag-digest mismatch — refusing to proceed." -ForegroundColor Red
    Write-Host "  $localLatest   -> $digestLatest"
    Write-Host "  $localVersion  -> $digestVersion"
    Write-Host "  $acrLatest     -> $digestAcrLatest"
    Write-Host "  $acrVersion    -> $digestAcrVer"
    throw "Tag-digest mismatch detected after build."
}

# -----------------------------------------------------------------------------
# Summary + next-step commands
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> Build complete. All four tags resolve to image $digestLatest."
Write-Host ""
Write-Host "   Next steps:"
Write-Host ""
Write-Host "   # 1. Authenticate to ACR and push both tags in one step:"
Write-Host "   ./deploy/push-image.ps1 -AcrName $AcrName -ImageVersion $ImageVersion"
Write-Host ""
Write-Host "   # (push-image.ps1 delegates to acr-login.ps1 internally — no separate auth step.)"
Write-Host ""
Write-Host "   # Or, if you'd rather drive the lower-level flow yourself:"
Write-Host "   ./deploy/acr-login.ps1 -AcrName $AcrName   # see deploy/ACR-AUTH.md"
Write-Host "   docker push $acrLatest"
Write-Host "   docker push $acrVersion"
Write-Host ""
Write-Host "   # 2. Wire the registry into a Container App revision (next sub-AC)."
Write-Host ""
