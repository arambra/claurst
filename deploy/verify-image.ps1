# verify-image.ps1 — confirm the pushed claurst-ask manifest is retrievable in ACR.
#
# PowerShell 7+ counterpart to verify-image.sh. Satisfies Sub-AC 50303.3:
# after build-image.ps1 + push-image.ps1 have produced and uploaded both
# ACR-bound tags (`:latest` and the immutable `:vMAJOR.MINOR.PATCH`),
# independently verify that the registry actually returns each tag's manifest
# AND that both names appear in its tag listing.
#
# Why this exists separately from push-image.ps1:
#   push-image.ps1 does an inline `az acr repository show --image` check on
#   the tags it just uploaded, but that's coupled to the push flow — it can
#   only prove "the upload I just did is reachable from the host that did
#   the upload, while its `az acr login` token is still warm". This script
#   is the "verify from another machine, days later, with only `az login`"
#   step:
#     * It DOES NOT need Docker — it talks to ACR's data plane via `az` only.
#     * It DOES NOT push or modify state — purely read-only.
#     * It uses BOTH `az acr repository show` (manifest digest per tag) AND
#       `az acr repository show-tags` (registry's authoritative tag listing),
#       so it catches the failure mode where a tag was reachable by digest
#       at push time but never made it into the listing the Container App
#       revision sees.
#
# Required parameters / env:
#   -AcrName             Globally-unique ACR name from provision-acr.ps1,
#                        5-50 alphanumerics, NO `.azurecr.io` suffix.
#                        Example: claurstacr1a2b3c
#
# Optional:
#   -ImageVersion        Versioned tag we expect to see, MUST match
#                        `vMAJOR.MINOR.PATCH` (default: v0.1.0). Match the
#                        value passed to build-image.ps1 / push-image.ps1 —
#                        a mismatch surfaces here as a clear "expected tag
#                        not in registry listing" error rather than a silent
#                        deploy of the wrong revision.
#   -ImageName           Repository name (default: claurst-ask). Override
#                        only if you're testing a fork.
#
# Examples:
#   ./deploy/verify-image.ps1 -AcrName claurstacr1a2b3c
#   ./deploy/verify-image.ps1 -AcrName claurstacr1a2b3c -ImageVersion v0.2.0
#
# Exit status:
#   0  both tags retrievable, both appear in the tag listing, digests agree
#   non-zero (throw)  any of: registry unreachable, repository missing,
#                     either tag missing, digests disagree, malformed input
#
# Idempotent + read-only: re-runnable as a smoke test from CI, a release-
# verification step, or a post-deploy sanity check.

[CmdletBinding()]
param(
    # Same constraint contract as every other deploy script — keeps a typo's
    # error message identical regardless of which step the operator is on.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9]{5,50}$')]
    [string] $AcrName,

    # Strict semver-with-v-prefix — same rule build-image.ps1 / push-image.ps1
    # enforce.
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $ImageVersion = 'v0.1.0',

    # Docker repo name spec: lowercase alphanumeric plus `.`, `_`, `-`.
    [ValidatePattern('^[a-z0-9]+([._-][a-z0-9]+)*$')]
    [string] $ImageName = 'claurst-ask'
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Preflight: az CLI present and a session is active.
# -----------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az not found on PATH — install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
}

# Cheapest "are we logged in?" probe. Works for both interactive `az login`
# and service-principal sessions; we don't need the output, only the exit
# code. Suppress stderr so a clean failure produces our message, not az's.
$null = az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw @"
No active Azure CLI session. Run 'az login' (interactive) or set up a service principal first.
For CI: AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID via 'az login --service-principal'.
"@
}

$loginServer     = "$AcrName.azurecr.io"
$expectedLatest  = 'latest'
$expectedVersion = $ImageVersion

Write-Host ">> Verifying ACR manifest:"
Write-Host "   Registry:    $loginServer"
Write-Host "   Repository:  $ImageName"
Write-Host "   Expected tags:"
Write-Host "     - $expectedLatest"
Write-Host "     - $expectedVersion"

# -----------------------------------------------------------------------------
# Step 1: confirm the repository exists at all.
#
# `az acr repository show --repository <name>` returns repo-level metadata
# (manifest count, last-updated-time, etc.). A missing repo here means the
# push never landed — fail with a message pointing back at push-image.ps1
# rather than letting the per-tag lookups below produce noisier errors.
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> [1/4] az acr repository show --repository $ImageName"

# Capture stderr alongside stdout so the operator sees az's actual error.
$repoInfo = az acr repository show `
    --name       $AcrName `
    --repository $ImageName `
    --output     json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $repoInfo -ForegroundColor Red
    throw "Repository '$ImageName' not found in registry '$AcrName'. Has push-image.ps1 been run for this ACR?"
}

Write-Host $repoInfo

# -----------------------------------------------------------------------------
# Step 2: list all tags and confirm both expected names are present.
#
# `show-tags` is the authoritative answer to "what does ACR think exists in
# this repo?". A tag can be unreachable via `--image` lookup briefly during
# replication; the listing is the steady-state truth a Container App
# revision will resolve against. We do this BEFORE the per-tag `show`
# calls so a missing tag surfaces as "expected tag not in listing" (the
# actionable failure) rather than "manifest fetch failed" (which doesn't
# tell the operator whether the tag was ever pushed or just briefly
# unreachable).
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> [2/4] az acr repository show-tags --repository $ImageName"

$tagsRaw = az acr repository show-tags `
    --name       $AcrName `
    --repository $ImageName `
    --output     tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $tagsRaw -ForegroundColor Red
    throw "Could not list tags for $loginServer/$ImageName."
}

# Normalize to an array of tag strings. `--output tsv` emits one tag per
# line; an empty repo emits nothing at all (which `-split` would render as
# a single empty string, hence the explicit Where-Object).
$tags = @($tagsRaw -split "`r?`n" | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

if ($tags.Count -eq 0) {
    throw @"
Tag listing for $ImageName is empty — repository exists but holds no tags.
Run push-image.ps1 to upload $expectedLatest and $expectedVersion.
"@
}

# Print the listing for the operator's records — useful when this script is
# being run as a release-gate by hand and the human wants to eyeball it.
$tags | ForEach-Object { Write-Host $_ }

# Use exact full-string match (NOT substring) so an unrelated tag like
# `v0.1.0-rc1` doesn't satisfy the expectation for `v0.1.0`.
$missing = @()
foreach ($expected in @($expectedLatest, $expectedVersion)) {
    if ($tags -notcontains $expected) {
        $missing += $expected
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Tag listing is missing expected tag(s): $($missing -join ', ')" -ForegroundColor Red
    throw "Run push-image.ps1 with the same -AcrName and -ImageVersion to upload them."
}

Write-Host ""
Write-Host "   Both expected tags present in registry listing."

# -----------------------------------------------------------------------------
# Step 3: per-tag manifest lookup via `az acr repository show --image`.
#
# This is the read every Container App revision will perform when it pulls;
# if it fails here it will fail at deploy time. We capture the manifest
# digest so step 4 can assert tag-pair coherence.
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> [3/4] az acr repository show --image ${ImageName}:<tag>"

$digestLatest = az acr repository show `
    --name   $AcrName `
    --image  "${ImageName}:${expectedLatest}" `
    --query  digest `
    --output tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $digestLatest -ForegroundColor Red
    throw "Could not retrieve manifest for $loginServer/${ImageName}:${expectedLatest}."
}

$digestVersion = az acr repository show `
    --name   $AcrName `
    --image  "${ImageName}:${expectedVersion}" `
    --query  digest `
    --output tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $digestVersion -ForegroundColor Red
    throw "Could not retrieve manifest for $loginServer/${ImageName}:${expectedVersion}."
}

$digestLatest  = ($digestLatest  -as [string]).Trim()
$digestVersion = ($digestVersion -as [string]).Trim()

if ([string]::IsNullOrEmpty($digestLatest) -or [string]::IsNullOrEmpty($digestVersion)) {
    Write-Host "  ${ImageName}:${expectedLatest}  -> '$digestLatest'"
    Write-Host "  ${ImageName}:${expectedVersion} -> '$digestVersion'"
    throw "Manifest digest came back empty for one or both tags."
}

Write-Host "   ${ImageName}:${expectedLatest}  -> $digestLatest"
Write-Host "   ${ImageName}:${expectedVersion} -> $digestVersion"

# -----------------------------------------------------------------------------
# Step 4: assert both tags resolve to the same manifest.
#
# build-image.ps1 + push-image.ps1 guarantee bit-for-bit equality at
# upload; checking it here closes the loop in case a third party (e.g. a
# CI job pinning `:latest` to a different release) snuck a divergent push
# between our build and our verify. This is the failure mode that would
# silently deploy `:vX.Y.Z` while shipping a different `:latest` to anyone
# pinning the rolling tag.
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> [4/4] Tag-pair coherence check"

if ($digestLatest -ne $digestVersion) {
    Write-Host "Remote digest mismatch — tags resolve to different content:" -ForegroundColor Red
    Write-Host "  ${ImageName}:${expectedLatest}  -> $digestLatest"
    Write-Host "  ${ImageName}:${expectedVersion} -> $digestVersion"
    throw "Re-run build-image.ps1 + push-image.ps1 from a clean checkout to recover."
}

Write-Host "   Both tags resolve to the same manifest digest."

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> Verification PASSED."
Write-Host "   $loginServer/$ImageName holds $expectedLatest and $expectedVersion"
Write-Host "   at digest $digestLatest."
Write-Host ""
Write-Host "   Pin a Container App revision to the immutable tag for production:"
Write-Host "     ${loginServer}/${ImageName}:${expectedVersion}"
