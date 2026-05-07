# push-image.ps1 — authenticate to ACR and push both tagged claurst-ask images.
#
# PowerShell 7+ counterpart to push-image.sh. Satisfies Sub-AC 50302.2: take
# the four-tag artefact produced by build-image.ps1 and ship the two ACR-bound
# tags (`:latest` and the immutable `:vMAJOR.MINOR.PATCH`) to the Azure
# Container Registry that provision-acr.ps1 stood up. Authentication is
# delegated to acr-login.ps1 so this script is "the push step" rather than
# "the auth-and-push step" — same separation of concerns provision-acr /
# acr-login / build-image already use.
#
# Why two pushes from one script (and not from build-image.ps1):
#   build-image.ps1 deliberately stays push-free so iterating on the
#   Dockerfile doesn't require ACR creds on every cycle. Once the operator is
#   happy with the local image, this script promotes BOTH ACR-bound tags
#   together. They already share a digest (build-image.ps1 asserts that);
#   pushing them as a pair keeps the rolling `:latest` and the immutable
#   `:vX.Y.Z` in lock-step in the registry, so a Container App revision
#   pinned to either ref pulls bit-for-bit identical content.
#
# Why we re-run acr-login.ps1 on every invocation:
#   `az acr login` tokens expire after ~3 hours. Calling the login script as
#   a delegate (rather than asking the operator to remember to run it first)
#   makes a fresh push idempotent: re-run this script any time the previous
#   `docker push` failed with `unauthorized`, and you're back in business
#   without having to consult ACR-AUTH.md.
#
# Required parameters / env:
#   -AcrName             Globally-unique ACR name from provision-acr.ps1,
#                        5-50 alphanumerics, NO `.azurecr.io` suffix.
#                        Example: claurstacr1a2b3c
#
# Optional:
#   -ImageVersion        Versioned tag, MUST match `vMAJOR.MINOR.PATCH`
#                        (default: v0.1.0). Must match the value passed to
#                        build-image.ps1 — mismatched values would push a tag
#                        that doesn't exist locally and `docker push` would
#                        fail loud, but we catch it client-side first to
#                        surface a clearer error.
#   -ImageName           Repository name (default: claurst-ask). Override
#                        only if you're testing a fork; do not change in
#                        mainline.
#
#   The service-principal parameters / env vars consumed by acr-login.ps1 are
#   forwarded transparently:
#   -ClientId / -ClientSecret / -TenantId
#   AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID
#
# Examples:
#   ./deploy/push-image.ps1 -AcrName claurstacr1a2b3c
#   ./deploy/push-image.ps1 -AcrName claurstacr1a2b3c -ImageVersion v0.2.0
#
#   # CI flow with an SP pre-staged in env vars:
#   $env:AZURE_CLIENT_ID = '...'; $env:AZURE_CLIENT_SECRET = '...'; $env:AZURE_TENANT_ID = '...'
#   ./deploy/push-image.ps1 -AcrName claurstacr1a2b3c
#
# Idempotent: re-running with the same -AcrName + -ImageVersion re-pushes the
# same digest under the same two tags. ACR de-dupes layers content-
# addressably, so repeat pushes only re-upload tag manifests, not blob content.

[CmdletBinding()]
param(
    # Mirrors the Bicep @minLength/@maxLength constraints and ACR's
    # alphanumeric-only rule, matching every other deploy script.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9]{5,50}$')]
    [string] $AcrName,

    # Strict semver-with-v-prefix — same rule build-image.ps1 enforces.
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $ImageVersion = 'v0.1.0',

    # Docker repo name spec: lowercase alphanumeric plus `.`, `_`, `-`.
    [ValidatePattern('^[a-z0-9]+([._-][a-z0-9]+)*$')]
    [string] $ImageName = 'claurst-ask',

    # Forwarded to acr-login.ps1; default each to the matching env var so a
    # CI pipeline can inject creds without re-templating the invocation.
    [string] $ClientId     = $env:AZURE_CLIENT_ID,
    [string] $ClientSecret = $env:AZURE_CLIENT_SECRET,
    [string] $TenantId     = $env:AZURE_TENANT_ID
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Preflight: docker available, daemon reachable, login script present.
# -----------------------------------------------------------------------------

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found on PATH — install Docker Desktop or the docker engine."
}

# Same daemon-reachability probe build-image.ps1 uses. Without it the first
# `docker push` would fail with a less-actionable error buried in HTTP output.
$null = docker info --format '{{.ServerVersion}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Cannot reach the Docker daemon. Start Docker Desktop / dockerd and retry."
}

$loginScript = Join-Path $PSScriptRoot 'acr-login.ps1'
if (-not (Test-Path -LiteralPath $loginScript -PathType Leaf)) {
    throw "Expected acr-login.ps1 next to this script at $loginScript, but it doesn't exist. Restore it from version control."
}

# -----------------------------------------------------------------------------
# Compute tag set (must match build-image.ps1 exactly).
# -----------------------------------------------------------------------------

$loginServer = "$AcrName.azurecr.io"
$acrLatest   = "$loginServer/${ImageName}:latest"
$acrVersion  = "$loginServer/${ImageName}:${ImageVersion}"

# Verify the two ACR-bound tags actually exist locally before we authenticate
# to the registry. If they don't, the operator skipped build-image.ps1 (or
# passed mismatched -AcrName / -ImageVersion) — bail with a clear message
# rather than burning an `az acr login` round-trip first.
foreach ($tag in @($acrLatest, $acrVersion)) {
    $null = docker image inspect --format '{{.Id}}' $tag 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw @"
Local tag '$tag' not found.
Run build-image.ps1 first with the same -AcrName and -ImageVersion:
  ./deploy/build-image.ps1 -AcrName $AcrName -ImageVersion $ImageVersion
"@
    }
}

# Both tags should share a digest after build-image.ps1; assert that here too
# so a hand-edited `docker tag` between build and push surfaces before we
# upload mismatched content to ACR.
$digestLatest  = (docker image inspect --format '{{.Id}}' $acrLatest).Trim()
$digestVersion = (docker image inspect --format '{{.Id}}' $acrVersion).Trim()

if ($digestLatest -ne $digestVersion) {
    Write-Host "Local tags disagree on image digest — refusing to push:" -ForegroundColor Red
    Write-Host "  $acrLatest  -> $digestLatest"
    Write-Host "  $acrVersion -> $digestVersion"
    throw "Local tag-digest mismatch detected. Re-run build-image.ps1 to re-tag both refs from the same build."
}

Write-Host ">> Pushing image to ACR:"
Write-Host "   Registry: $loginServer"
Write-Host "   Tags:     $acrLatest"
Write-Host "             $acrVersion"
Write-Host "   Digest:   $digestLatest"

# -----------------------------------------------------------------------------
# Step 1: authenticate to ACR (delegated to acr-login.ps1).
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> Authenticating to $loginServer via acr-login.ps1..."

# Build a parameter splat so we only pass SP creds when all three are
# populated. acr-login.ps1 already enforces the all-or-none rule, but
# forwarding empty strings would trip its validation; this keeps the
# delegation clean for both the local-interactive and CI flows.
$loginArgs = @{ AcrName = $AcrName }
if ($ClientId -and $ClientSecret -and $TenantId) {
    $loginArgs.ClientId     = $ClientId
    $loginArgs.ClientSecret = $ClientSecret
    $loginArgs.TenantId     = $TenantId
}
& $loginScript @loginArgs
if ($LASTEXITCODE -ne 0) {
    throw "acr-login.ps1 failed (exit $LASTEXITCODE). See its output above for details."
}

# -----------------------------------------------------------------------------
# Step 2: push both tags (same digest, two refs).
# -----------------------------------------------------------------------------

# Push the immutable version FIRST so that if the network drops between the
# two pushes, what's in ACR is the pinned release rather than a `:latest`
# that floats. ACR is content-addressable, so the second push only uploads
# the tag manifest (a few hundred bytes) — blobs are deduped server-side.
Write-Host ""
Write-Host ">> Pushing $acrVersion..."
docker push $acrVersion
if ($LASTEXITCODE -ne 0) {
    throw "docker push $acrVersion failed (exit $LASTEXITCODE)."
}

Write-Host ""
Write-Host ">> Pushing $acrLatest..."
docker push $acrLatest
if ($LASTEXITCODE -ne 0) {
    throw "docker push $acrLatest failed (exit $LASTEXITCODE)."
}

# -----------------------------------------------------------------------------
# Step 3: verify ACR sees both tags pointing at the same manifest.
# -----------------------------------------------------------------------------

# `az acr repository show` rather than `docker manifest inspect` because the
# former works without DOCKER_CLI_EXPERIMENTAL=enabled and has consistent
# output across docker / podman / nerdctl. A mismatch here should be
# impossible given the local-digest equality we asserted, but it's cheap to
# verify and surfaces transient registry corruption immediately.
Write-Host ""
Write-Host ">> Verifying both tags resolve to the same manifest in ACR..."

$remoteDigestLatest = az acr repository show `
    --name  $AcrName `
    --image "${ImageName}:latest" `
    --query digest `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az acr repository show for :latest failed (exit $LASTEXITCODE)." }

$remoteDigestVersion = az acr repository show `
    --name  $AcrName `
    --image "${ImageName}:${ImageVersion}" `
    --query digest `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az acr repository show for :${ImageVersion} failed (exit $LASTEXITCODE)." }

$remoteDigestLatest  = $remoteDigestLatest.Trim()
$remoteDigestVersion = $remoteDigestVersion.Trim()

if ([string]::IsNullOrEmpty($remoteDigestLatest) -or [string]::IsNullOrEmpty($remoteDigestVersion)) {
    throw "Could not read manifest digests back from ACR — verify the registry is reachable."
}

if ($remoteDigestLatest -ne $remoteDigestVersion) {
    Write-Host "Remote digest mismatch — ACR shows different content for the two tags:" -ForegroundColor Red
    Write-Host "  $acrLatest  -> $remoteDigestLatest"
    Write-Host "  $acrVersion -> $remoteDigestVersion"
    throw "Remote digest mismatch. Re-run build-image.ps1 + push-image.ps1 to recover."
}

# -----------------------------------------------------------------------------
# Summary + next-step commands.
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> Push complete. ACR holds both tags at digest $remoteDigestLatest."
Write-Host ""
Write-Host "   Verify from another machine:"
Write-Host "     az acr repository show-tags --name $AcrName --repository $ImageName --output tsv"
Write-Host ""
Write-Host "   Next step:"
Write-Host "     # Wire the registry into a Container App revision (next sub-AC)."
Write-Host "     # The Container App will pull $loginServer/${ImageName}:${ImageVersion}"
Write-Host "     # using the registry's admin-user credentials configured in deploy/secrets/."
Write-Host ""
