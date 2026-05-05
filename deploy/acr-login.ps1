# acr-login.ps1 — authenticate the local/CI environment to the provisioned ACR.
#
# PowerShell 7+ counterpart to acr-login.sh. Satisfies Sub-AC 3.3: a single,
# focused script that handles ACR authentication for both interactive developer
# workstations AND headless CI runners, so subsequent `docker push` commands
# from provision-acr.ps1's "next steps" block actually have credentials.
#
# Why this exists separately from provision-acr.ps1:
#   provision-acr.ps1 runs once when the registry is first stood up; this
#   script runs every time someone (or CI) needs to push a new image. Splitting
#   them keeps the "stand up infra" step idempotent-but-rare and the "push an
#   image" step idempotent-and-cheap.
#
# Two flows are supported:
#
#   1. Local interactive (default):
#      The caller has already done `az login` in their browser. We just refresh
#      Docker's stored credential helper for `<acr>.azurecr.io` via `az acr login`.
#
#   2. CI / headless (when service-principal parameters are passed):
#      We log in with a service principal first (non-interactive), then run
#      the same `az acr login`. This is the GitHub Actions / Azure DevOps shape:
#      AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID supplied as
#      pipeline secrets, surfaced either as parameters or as env vars.
#
# A third sub-flow — `-Mode Token` — emits a short-lived ACR access token to
# stdout instead of touching the Docker daemon. This unblocks build environments
# that don't ship Docker (kaniko, buildah, devcontainer-without-DinD), where the
# image build step accepts a registry token directly.
#
# Required parameters / env:
#   -AcrName             Registry name (5-50 alphanumerics, no domain suffix).
#                        Example: claurstacr1a2b3c — same value passed to
#                        provision-acr.ps1; do NOT include `.azurecr.io`.
#
# Optional service-principal parameters (default to env vars when omitted):
#   -ClientId            Service-principal app ID (env: AZURE_CLIENT_ID)
#   -ClientSecret        SP password / secret    (env: AZURE_CLIENT_SECRET)
#   -TenantId            AAD tenant ID           (env: AZURE_TENANT_ID)
#
# Optional flow control:
#   -Mode  Docker | Token   `Docker` (default) refreshes the local Docker
#                           credential helper. `Token` prints a short-lived
#                           ACR access token to stdout for daemonless builders.
#
# Examples:
#
#   # Local developer (already `az login`'d):
#   ./deploy/acr-login.ps1 -AcrName claurstacr1a2b3c
#
#   # CI runner with SP creds in env (set by the pipeline as secrets):
#   $env:AZURE_CLIENT_ID     = '...'
#   $env:AZURE_CLIENT_SECRET = '...'
#   $env:AZURE_TENANT_ID     = '...'
#   ./deploy/acr-login.ps1 -AcrName claurstacr1a2b3c
#
#   # Daemonless builder — capture the token:
#   ./deploy/acr-login.ps1 -AcrName claurstacr1a2b3c -Mode Token > token.txt

[CmdletBinding()]
param(
    # ValidatePattern mirrors the Bicep @minLength/@maxLength constraints and
    # ACR's "alphanumeric only" rule, matching provision-acr.ps1.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9]{5,50}$')]
    [string] $AcrName,

    # Default each SP parameter to the matching env var so a CI pipeline can
    # inject credentials without re-templating the invocation. Empty string
    # (rather than $null) is the AzureCLI/PowerShell convention here.
    [string] $ClientId     = $env:AZURE_CLIENT_ID,
    [string] $ClientSecret = $env:AZURE_CLIENT_SECRET,
    [string] $TenantId     = $env:AZURE_TENANT_ID,

    [ValidateSet('Docker', 'Token')]
    [string] $Mode = 'Docker'
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Preflight: az CLI present
# -----------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI"
}

# -----------------------------------------------------------------------------
# Step 1: ensure we have an Azure context
# -----------------------------------------------------------------------------

# Treat the SP triple (ClientId + ClientSecret + TenantId) as a unit. Any subset
# is a misconfiguration; better to catch it here than three commands deeper.
$spProvided = @($ClientId, $ClientSecret, $TenantId | Where-Object { $_ }).Count

if ($spProvided -gt 0 -and $spProvided -lt 3) {
    throw "Service-principal flow requires ALL of -ClientId, -ClientSecret, -TenantId (or AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID)."
}

if ($spProvided -eq 3) {
    Write-Host ">> Logging in with service principal (CI flow)..."
    # --output none silences the subscription JSON `az login` prints, which can
    # include tenant metadata we don't want in CI logs.
    az login `
        --service-principal `
        --username $ClientId `
        --password $ClientSecret `
        --tenant   $TenantId `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az login --service-principal failed (exit $LASTEXITCODE)" }
}
else {
    # Local interactive flow. Don't auto-run `az login` — on a CI runner that
    # would open a browser and hang forever. Fail loud with the fix instead.
    $null = az account show --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Not logged in to Azure. Run 'az login' first (interactive), or pass -ClientId/-ClientSecret/-TenantId (or set AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID) for the CI flow."
    }
}

$subscriptionName = az account show --query name --output tsv
Write-Host ">> Active subscription: $subscriptionName"
Write-Host ">> Target registry: $AcrName.azurecr.io"

# -----------------------------------------------------------------------------
# Step 2: authenticate to the registry
# -----------------------------------------------------------------------------

if ($Mode -eq 'Token') {
    # `--expose-token` does NOT touch the Docker daemon; it returns a JSON blob
    # whose `accessToken` is a short-lived ACR refresh token. Build tools that
    # speak the registry API directly (kaniko, buildah, oras) consume this.
    # The matching username for token auth is always the literal GUID
    # 00000000-0000-0000-0000-000000000000.
    Write-Host ">> Issuing short-lived ACR access token (no Docker daemon required)..."
    az acr login `
        --name $AcrName `
        --expose-token `
        --output tsv `
        --query accessToken
    if ($LASTEXITCODE -ne 0) { throw "az acr login --expose-token failed (exit $LASTEXITCODE)" }
}
else {
    # Default flow: refresh Docker's stored credential helper so subsequent
    # `docker push <loginServer>/...` calls succeed. `az acr login` resolves to
    # `docker login` under the hood with a short-lived token.
    Write-Host ">> Authenticating Docker daemon to $AcrName.azurecr.io..."
    az acr login --name $AcrName
    if ($LASTEXITCODE -ne 0) { throw "az acr login failed (exit $LASTEXITCODE)" }

    Write-Host ""
    Write-Host ">> Authenticated. You can now push images:"
    Write-Host "   docker push $AcrName.azurecr.io/claurst-ask:<tag>"
    Write-Host ""
    Write-Host "   Token lifetime is ~3 hours; re-run this script to refresh."
}
