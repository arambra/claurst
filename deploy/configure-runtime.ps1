# configure-runtime.ps1 — converge a deployed Container App's runtime configuration
# (ingress + secrets + env vars) to the shape the /ask REST endpoint requires.
#
# PowerShell 7+ counterpart to configure-runtime.sh. Satisfies AC 40103
# Sub-AC 3: "Configure Container App ingress (external, target port) and
# environment variables/secrets required for the /ask endpoint runtime."
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
# `provision-app.ps1` already creates an app with `--ingress external`,
# `--target-port 8080`, and a 240-second ingress idle timeout.
# `setup-secrets.ps1` already stores the two secrets and binds them to env
# vars. This script is the single coherent "runtime config converger": it
# asserts both halves at once, so re-running it brings any drifted Container
# App back to the desired state without forcing the operator to remember
# which subset of the previous scripts to re-run.
#
# What this script does, in order:
#   1. Confirms `az` is installed, the caller is logged in, and the
#      `containerapp` extension is current.
#   2. Confirms the Container App exists (fails fast otherwise — there is
#      nothing to configure if `provision-app.ps1` hasn't been run).
#   3. Re-asserts ingress: external visibility, target port, 4-minute
#      (240 s) idle timeout. Each setting is idempotent under
#      `az containerapp ingress {enable,update}`.
#   4. Stores the two Container Apps secrets (`deepseek-api-key`,
#      `claurst-api-key`).
#   5. Binds the secrets to environment variables (`DEEPSEEK_API_KEY`,
#      `CLAURST_API_KEY`) on the running container via `secretref:`
#      indirection. Literal values never appear in the revision template.
#   6. Verifies the resulting configuration: prints both secret names,
#      both env-var names with their `secretRef` targets, ingress fields,
#      and the public FQDN.
#
# Required parameters (positional or named):
#   -ResourceGroup     Resource group containing the Container App
#                      (must match provision-app.ps1).
#   -ContainerApp      Name of the Container App (e.g. claurst-ask).
#   -DeepseekApiKey    Outbound key for DeepSeek's Anthropic-compatible API.
#   -ClaurstApiKey     Inbound shared secret callers send as X-API-Key.
#                      Generate once and share with callers; the binary
#                      refuses to start without it.
#
# Optional parameters:
#   -TargetPort         Container port the binary listens on (default: 8080,
#                       matches Dockerfile EXPOSE).
#   -IdleTimeoutMinutes Ingress request idle timeout in minutes
#                       (default: 4 == 240 s, matches the seed's
#                       synchronous-blocking constraint).
#
# Example:
#   $deepseek = Read-Host -AsSecureString "DeepSeek key"
#   $inbound  = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
#   ./deploy/configure-runtime.ps1 `
#     -ResourceGroup  rg-claurst `
#     -ContainerApp   claurst-ask `
#     -DeepseekApiKey (ConvertFrom-SecureString $deepseek -AsPlainText) `
#     -ClaurstApiKey  $inbound
#
# Re-running the script with the same inputs is safe: every `az` call below
# is idempotent under the chosen invocation. Rotating either secret value
# only requires re-running this script with the new value(s) and restarting
# the active revision — no template change.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,

    # ValidatePattern mirrors Container Apps name rules: 2-32 chars,
    # lowercase alphanumeric + hyphens, must start and end alphanumeric.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$')]
    [string] $ContainerApp,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $DeepseekApiKey,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ClaurstApiKey,

    # Target port sanity: must be a valid 16-bit port. The Dockerfile's
    # EXPOSE 8080 is what the binary actually binds to; allowing operators
    # to override is purely for unusual side-loaded builds.
    [ValidateRange(1, 65535)]
    [int] $TargetPort = 8080,

    # Idle timeout sanity: Container Apps caps this at 240 minutes; the Seed
    # requires 4 (== 240 s of synchronous-blocking time).
    [ValidateRange(1, 240)]
    [int] $IdleTimeoutMinutes = 4
)

$ErrorActionPreference = 'Stop'

# Empty inbound secrets would silently let every "anonymous" caller through
# at the auth layer. ValidateNotNullOrEmpty catches `$null` and ''; the
# whitespace-only check below catches the ' ' case which Validate accepts.
if ([string]::IsNullOrWhiteSpace($DeepseekApiKey)) {
    throw "-DeepseekApiKey must not be blank — got only whitespace."
}
if ([string]::IsNullOrWhiteSpace($ClaurstApiKey)) {
    throw "-ClaurstApiKey must not be blank — got only whitespace. Generate one with e.g. [Guid]::NewGuid().ToString('N')."
}

# -----------------------------------------------------------------------------
# Preflight: az CLI present, authenticated, containerapp extension installed
# -----------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI"
}

$null = az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first."
}

$subscriptionName = az account show --query name --output tsv
$subscriptionId   = az account show --query id   --output tsv

Write-Host ">> Active subscription: $subscriptionName ($subscriptionId)"
Write-Host ">> Container App:       $ContainerApp (group: $ResourceGroup)"
Write-Host ">> Target port:         $TargetPort"
Write-Host ">> Idle timeout:        $IdleTimeoutMinutes minutes"

Write-Host ">> Ensuring 'containerapp' Azure CLI extension is installed..."
$installed = az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($installed)) {
    az extension add --name containerapp --only-show-errors --yes --output none
    if ($LASTEXITCODE -ne 0) { throw "az extension add (containerapp) failed (exit $LASTEXITCODE). If pip is crashing with 0xC0000005, see deploy/README troubleshooting." }
} else {
    Write-Host "   (already installed; skipping add/upgrade)"
}

# -----------------------------------------------------------------------------
# Step 1: confirm the Container App exists
# -----------------------------------------------------------------------------

# We deliberately do *not* create the app here — that's provision-app.ps1's
# job, and silently materialising one would skip its registry + identity
# wiring. Surface a clear "run the prereq" error instead.
$existingAppId = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query id `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($existingAppId)) {
    throw "Container App '$ContainerApp' not found in resource group '$ResourceGroup'. Run deploy/provision-app.ps1 first to create the app, then re-run this script to configure its runtime."
}

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
Write-Host ">> Re-asserting ingress: external visibility, port $TargetPort, transport auto..."
az containerapp ingress enable `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --type external `
    --target-port $TargetPort `
    --transport auto `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az containerapp ingress enable failed (exit $LASTEXITCODE)" }

$idleSeconds = $IdleTimeoutMinutes * 60
Write-Host ">> Setting ingress idle timeout to $IdleTimeoutMinutes minute(s) (${idleSeconds}s)..."
az containerapp ingress update `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --idle-timeout-in-minutes $IdleTimeoutMinutes `
    --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "ingress idle-timeout setter unavailable on this az version — the platform default of 240s still applies; upgrade az to silence this notice."
    # Reset $LASTEXITCODE so the next az call's exit-code check isn't poisoned.
    $global:LASTEXITCODE = 0
}

# -----------------------------------------------------------------------------
# Step 3: store the two Container Apps secrets
# -----------------------------------------------------------------------------

# `az containerapp secret set` is the canonical way to write into the
# Container App's encrypted secret store. The literal values never appear in:
#   • `az containerapp show` output
#   • ARM exports / template captures
#   • activity logs / audit logs
# They are decrypted only at container start, in-memory inside the
# platform's revision controller. Rotation is just a re-run with new values
# + a revision restart (see `deploy/secrets/README.md`).
#
# Naming convention: lowercase-hyphenated for the secret name (Azure
# requirement; `_` is rejected), UPPER_SNAKE for the env-var binding.
Write-Host ">> Storing secrets on Container App '$ContainerApp'..."
az containerapp secret set `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --secrets `
        "deepseek-api-key=$DeepseekApiKey" `
        "claurst-api-key=$ClaurstApiKey" `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az containerapp secret set failed (exit $LASTEXITCODE)" }

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
Write-Host ">> Binding secrets to environment variables on the running container..."
az containerapp update `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --set-env-vars `
        "DEEPSEEK_API_KEY=secretref:deepseek-api-key" `
        "CLAURST_API_KEY=secretref:claurst-api-key" `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az containerapp update failed (exit $LASTEXITCODE)" }

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
Write-Host ">> Verifying configuration..."

$ingressExternal = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.external `
    --output tsv

$ingressTargetPort = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.targetPort `
    --output tsv

$ingressFqdn = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.fqdn `
    --output tsv

# Sanity-check ingress visibility — `external` must literally be "true".
# A `false` here would mean inbound traffic from the public internet can't
# reach /ask, which violates the seed's "public HTTPS ingress" constraint.
if ($ingressExternal -ne 'true') {
    throw "Ingress is not external (got '$ingressExternal'). The /ask endpoint will not be publicly reachable."
}

if ([string] $ingressTargetPort -ne [string] $TargetPort) {
    throw "Ingress target port mismatch: requested $TargetPort, app reports $ingressTargetPort."
}

# Asking for both secrets and both env vars in a single `show` round-trip
# keeps the verification cost to one ARM call instead of four.
Write-Host ">> Secrets and env-var bindings:"
az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query "{secrets: properties.configuration.secrets[].name, env: properties.template.containers[0].env[?name=='DEEPSEEK_API_KEY' || name=='CLAURST_API_KEY']}" `
    --output table

Write-Host ""
Write-Host ">> Runtime configuration converged."
Write-Host "   Container App:    $ContainerApp"
Write-Host "   Resource group:   $ResourceGroup"
Write-Host "   Ingress:          external (https://$ingressFqdn)"
Write-Host "   Target port:      $ingressTargetPort"
Write-Host "   Idle timeout:     $IdleTimeoutMinutes minute(s)"
Write-Host "   Secrets:          deepseek-api-key, claurst-api-key"
Write-Host "   Env vars wired:   DEEPSEEK_API_KEY -> secretref:deepseek-api-key"
Write-Host "                     CLAURST_API_KEY  -> secretref:claurst-api-key"
Write-Host ""
Write-Host "   Smoke-test the endpoint (`$env:CLAURST_API_KEY must be the value passed in):"
Write-Host "   curl -sSf -X POST https://$ingressFqdn/ask ``"
Write-Host "     -H `"X-API-Key: `$env:CLAURST_API_KEY`" ``"
Write-Host "     -H 'Content-Type: application/json' ``"
Write-Host "     -d '{`"question`":`"What is the capital of France?`"}'"
Write-Host ""
Write-Host "   Tail logs:"
Write-Host "   az containerapp logs show ``"
Write-Host "     --name $ContainerApp ``"
Write-Host "     --resource-group $ResourceGroup ``"
Write-Host "     --follow"
Write-Host ""
