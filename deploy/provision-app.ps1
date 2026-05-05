# provision-app.ps1 — create the Azure Container App that runs `claude serve`,
# pulls its image from ACR via a user-assigned managed identity, and exposes
# POST /ask on a public HTTPS ingress.
#
# PowerShell 7+ counterpart to provision-app.sh. Satisfies AC 40102 Sub-AC 2:
# provision the Container App resource referencing the ACR-hosted image with
# the managed identity attached for ACR pull authentication. Direct `az` CLI
# only — no Bicep, no Terraform, no `azd`. The Seed forbids IaC for the
# Container App itself; only the registry has a Bicep template (deploy/acr.bicep).
#
# Pre-requisites (run these scripts first, in order):
#   1. deploy/provision-acr.ps1        → ACR exists; -AcrName is its name.
#   2. deploy/provision-env.ps1        → Container Apps environment exists;
#                                        -ContainerAppsEnv is its name.
#   3. deploy/provision-identity.ps1   → User-assigned managed identity exists
#                                        with the AcrPull role granted on the ACR;
#                                        -IdentityName is its name.
#   4. (Optional) deploy/push-image.ps1 → at least one tagged image exists at
#                                        <Acr>.azurecr.io/<ImageName>:<ImageTag>.
#
# What this script does, in order:
#   1. Confirms `az` is installed, the caller is logged in, and the
#      `containerapp` extension is current (matches provision-env.ps1).
#   2. Resolves the user-assigned managed identity's ARM resource ID + clientId
#      from (-IdentityName, -IdentityResourceGroup) — fails fast if the UAMI
#      hasn't been provisioned yet.
#   3. Resolves the ACR login server (e.g. claurstacr123.azurecr.io) so the
#      caller doesn't have to remember whether to include `.azurecr.io`.
#   4. Verifies the Container Apps environment exists in the workload group
#      (Sub-AC 2 must not silently materialize a fresh environment — that would
#      bypass provision-env.ps1's Log Analytics wiring).
#   5. Creates the Container App if it does not exist, or updates the existing
#      one's image / replica configuration if it does. Both paths leave the app
#      with:
#        - the UAMI attached (`--user-assigned`)
#        - ACR pulls authenticated via that UAMI (`--registry-identity`)
#        - public HTTPS ingress on -TargetPort (default 8080)
#        - exactly one replica (min=max=1, no auto-scale, single revision)
#   6. Sets the platform request-timeout knob (`requestIdleTimeout = 4 minutes`,
#      = 240s) on the ingress to match the Seed's synchronous-blocking AC. The
#      Container Apps default already caps requests at 240s, but pinning the
#      idle timeout keeps the configuration auditable and explicit.
#   7. Prints the public FQDN so the operator can curl POST /ask immediately.
#
# Required parameters (positional or named):
#   -ResourceGroup           Workload resource group (default: FGF-EDI-SANDBOX;
#                            must match provision-env.ps1).
#   -ContainerAppName        Container App name (default: mapagent). 2-32 chars,
#                            lowercase alphanumeric + hyphens; appears as the
#                            per-app DNS label.
#   -ContainerAppsEnv        Name of the managed environment from provision-env.ps1
#                            (default: mapagentenv).
#   -AcrName                 Name (without `.azurecr.io`) of the registry from
#                            provision-acr.ps1 (default: mapagentacr).
#   -IdentityName            Name of the user-assigned managed identity from
#                            provision-identity.ps1 (default: mapagentid).
#   -ImageTag                Image tag to deploy (e.g. v0.1.0, latest, a git SHA).
#                            The image is resolved as
#                            <AcrName>.azurecr.io/<ImageName>:<ImageTag>.
#
# Optional parameters:
#   -ImageName               Image repo name within the registry (default: map-agent).
#   -TargetPort              Container port the binary listens on (default: 8080,
#                            matches the Dockerfile's EXPOSE).
#   -AcrResourceGroup        Group containing the ACR if separate from
#                            -ResourceGroup (default: -ResourceGroup).
#   -IdentityResourceGroup   Group containing the UAMI if separate from
#                            -ResourceGroup (default: -ResourceGroup).
#   -EnvResourceGroup        Group containing the Container Apps environment if
#                            separate from -ResourceGroup (default: -ResourceGroup).
#
# Example:
#   ./deploy/provision-app.ps1 -ImageTag v0.1.0
#   # (uses defaults: -ResourceGroup FGF-EDI-SANDBOX, -ContainerAppName mapagent,
#   #                 -ContainerAppsEnv mapagentenv, -AcrName mapagentacr,
#   #                 -IdentityName mapagentid, -ImageName map-agent)
#
# Re-running the script with the same inputs is safe: an existing app is
# updated rather than re-created, and image / replica / identity settings are
# all idempotent under the chosen `az containerapp update` invocations.

[CmdletBinding()]
param(
    [string] $ResourceGroup = 'FGF-EDI-SANDBOX',

    # ValidatePattern mirrors Container Apps name rules: 2-32 chars, lowercase
    # alphanumeric + hyphens, must start and end alphanumeric. Catches typos
    # client-side (same posture as provision-env.ps1's environment validation).
    [ValidatePattern('^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$')]
    [string] $ContainerAppName = 'mapagent',

    [string] $ContainerAppsEnv = 'mapagentenv',

    # Mirror the ACR name validation from provision-acr.ps1 so a typo here
    # gets caught locally instead of as a 404 from `az acr show`.
    [ValidatePattern('^[a-zA-Z0-9]{5,50}$')]
    [string] $AcrName = 'mapagentacr',

    # Mirror the managed-identity name rules from provision-identity.ps1.
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{2,127}$')]
    [string] $IdentityName = 'mapagentid',

    [Parameter(Mandatory = $true)] [string] $ImageTag,

    [string] $ImageName             = 'map-agent',

    # Target port sanity: must be a valid 16-bit port. The Dockerfile's
    # EXPOSE 8080 is what the binary actually binds to; allowing operators to
    # override is purely for unusual side-loaded builds.
    [ValidateRange(1, 65535)]
    [int] $TargetPort               = 8080,

    [string] $AcrResourceGroup      = '',
    [string] $IdentityResourceGroup = '',
    [string] $EnvResourceGroup      = ''
)

$ErrorActionPreference = 'Stop'

# Default the secondary groups to the workload group if the operator didn't
# pass any. Done after param() so we have access to $ResourceGroup as the
# fallback. Kept as separate parameters (not a single -SharedResourceGroup)
# because the registry, UAMI, and environment can each legitimately live in
# their own "platform" group in a larger Azure landing-zone setup.
if ([string]::IsNullOrWhiteSpace($AcrResourceGroup))      { $AcrResourceGroup      = $ResourceGroup }
if ([string]::IsNullOrWhiteSpace($IdentityResourceGroup)) { $IdentityResourceGroup = $ResourceGroup }
if ([string]::IsNullOrWhiteSpace($EnvResourceGroup))      { $EnvResourceGroup      = $ResourceGroup }

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

$imageRef = "$AcrName.azurecr.io/$ImageName`:$ImageTag"

Write-Host ">> Active subscription: $subscriptionName ($subscriptionId)"
Write-Host ">> Container App:       $ContainerAppName (group: $ResourceGroup)"
Write-Host ">> Environment:         $ContainerAppsEnv (group: $EnvResourceGroup)"
Write-Host ">> Registry:            $AcrName (group: $AcrResourceGroup)"
Write-Host ">> Identity (UAMI):     $IdentityName (group: $IdentityResourceGroup)"
Write-Host ">> Image:               $imageRef"
Write-Host ">> Target port:         $TargetPort"

Write-Host ">> Ensuring 'containerapp' Azure CLI extension is installed..."
$installed = az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($installed)) {
    az extension add --name containerapp --only-show-errors --yes --output none
    if ($LASTEXITCODE -ne 0) { throw "az extension add (containerapp) failed (exit $LASTEXITCODE). If pip is crashing with 0xC0000005, see deploy/README troubleshooting." }
} else {
    Write-Host "   (already installed; skipping add/upgrade)"
}

# -----------------------------------------------------------------------------
# Step 1: resolve the user-assigned managed identity
# -----------------------------------------------------------------------------

# We need two fields off the UAMI:
#   • id        — passed to `--user-assigned` (attach the identity to the app)
#                 and `--registry-identity` (use it for ACR auth on pulls).
#   • clientId  — surfaced in the summary block so the operator can sanity-check
#                 the federated client without a second round-trip.
# Failing here means provision-identity.ps1 hasn't been run; the error message
# points the operator at the right script.
Write-Host ">> Resolving user-assigned managed identity..."
$identityResourceId = az identity show `
    --name $IdentityName `
    --resource-group $IdentityResourceGroup `
    --query id `
    --output tsv 2>$null

$identityClientId = az identity show `
    --name $IdentityName `
    --resource-group $IdentityResourceGroup `
    --query clientId `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($identityResourceId) -or
    [string]::IsNullOrWhiteSpace($identityClientId)) {
    throw "User-assigned managed identity '$IdentityName' not found in resource group '$IdentityResourceGroup'. Run deploy/provision-identity.ps1 first, or set -IdentityResourceGroup if the UAMI lives in a different group."
}

# -----------------------------------------------------------------------------
# Step 2: resolve the ACR login server (and confirm the registry exists)
# -----------------------------------------------------------------------------

# `az acr show --query loginServer` returns `<acr>.azurecr.io`. Resolving from
# the registry record (rather than string-concatenating ourselves) means an
# ACR with a custom data-plane suffix — e.g. an Azure Government tenant with
# `.azurecr.us` — Just Works.
Write-Host ">> Resolving ACR login server..."
$acrLoginServer = az acr show `
    --name $AcrName `
    --resource-group $AcrResourceGroup `
    --query loginServer `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($acrLoginServer)) {
    throw "ACR '$AcrName' not found in resource group '$AcrResourceGroup'. Run deploy/provision-acr.ps1 first, or set -AcrResourceGroup if the registry lives in a different group."
}

# Re-derive the image reference now that we have the canonical login server.
# This handles the (rare) case where -AcrName is a sovereign-cloud registry
# whose data plane uses something other than `.azurecr.io`.
$imageRef = "$acrLoginServer/$ImageName`:$ImageTag"

# -----------------------------------------------------------------------------
# Step 3: confirm the Container Apps environment exists
# -----------------------------------------------------------------------------

# We deliberately do *not* create the environment here — that's
# provision-env.ps1's job, and silently materialising a fresh one would skip
# its Log Analytics wiring. Surface a clear "run the prereq" error instead.
Write-Host ">> Resolving Container Apps environment..."
$envResourceId = az containerapp env show `
    --name $ContainerAppsEnv `
    --resource-group $EnvResourceGroup `
    --query id `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($envResourceId)) {
    throw "Container Apps environment '$ContainerAppsEnv' not found in resource group '$EnvResourceGroup'. Run deploy/provision-env.ps1 first, or set -EnvResourceGroup if the environment lives in a different group."
}

# -----------------------------------------------------------------------------
# Step 4: create or update the Container App
# -----------------------------------------------------------------------------

# Pre-flight existence check: `az containerapp show` exits non-zero when the
# app doesn't exist. Branching on this lets us call `create` only on the first
# run and `update` afterwards, which is the cleanest path to idempotency given
# `az containerapp create` 409s on duplicates.
$existingAppId = az containerapp show `
    --name $ContainerAppName `
    --resource-group $ResourceGroup `
    --query id `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($existingAppId)) {
    Write-Host ">> Creating Container App '$ContainerAppName' (this can take a couple of minutes)..."
    # Flag-by-flag rationale (mirrors provision-app.sh):
    #   --environment <id>            : pin to the env resolved in Step 3.
    #   --image <ref>                 : ACR-hosted runtime image.
    #   --user-assigned <UAMI id>     : attach the UAMI so the running container
    #                                   inherits the identity.
    #   --registry-server <login>     : tell Container Apps which registry to
    #                                   pull from. Required alongside
    #                                   --registry-identity.
    #   --registry-identity <UAMI id> : authenticate ACR pulls via the UAMI's
    #                                   AcrPull grant (provision-identity.ps1
    #                                   created this), eliminating the ACR
    #                                   admin password from Container Apps secrets.
    #   --ingress external            : public HTTPS endpoint via the managed
    #                                   reverse proxy.
    #   --target-port <port>          : the port `claude serve` binds to inside
    #                                   the container (Dockerfile EXPOSE 8080).
    #   --transport auto              : let the platform pick HTTP/1.1 vs HTTP/2.
    #   --min-replicas 1              : no scale-to-zero — cold starts here would
    #                                   blow past the 240s sync deadline.
    #   --max-replicas 1              : single replica, no auto-scale (Seed:
    #                                   "single Azure Container Apps instance").
    #   --revisions-mode single       : only one active revision at a time.
    az containerapp create `
        --name $ContainerAppName `
        --resource-group $ResourceGroup `
        --environment $envResourceId `
        --image $imageRef `
        --user-assigned $identityResourceId `
        --registry-server $acrLoginServer `
        --registry-identity $identityResourceId `
        --ingress external `
        --target-port $TargetPort `
        --transport auto `
        --min-replicas 1 `
        --max-replicas 1 `
        --revisions-mode single `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az containerapp create failed (exit $LASTEXITCODE)" }
}
else {
    Write-Host ">> Container App '$ContainerAppName' already exists — updating image and replica config..."
    # Update path: don't repeat `--environment` (immutable) or `--ingress`
    # (its own subcommand). The four flags below are the ones that safely
    # converge a previously-deployed app to the desired state on every re-run.
    az containerapp update `
        --name $ContainerAppName `
        --resource-group $ResourceGroup `
        --image $imageRef `
        --min-replicas 1 `
        --max-replicas 1 `
        --revisions-mode single `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az containerapp update failed (exit $LASTEXITCODE)" }

    # Identity attachment and ACR-pull-via-identity have to be re-asserted via
    # their dedicated subcommands; `az containerapp update` doesn't accept the
    # `--user-assigned` / `--registry-identity` flags (those are create-only).
    # Both calls below are idempotent and no-op on the existing config.
    Write-Host ">> Ensuring user-assigned identity is attached..."
    az containerapp identity assign `
        --name $ContainerAppName `
        --resource-group $ResourceGroup `
        --user-assigned $identityResourceId `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az containerapp identity assign failed (exit $LASTEXITCODE)" }

    Write-Host ">> Ensuring ACR pulls authenticate via the UAMI..."
    az containerapp registry set `
        --name $ContainerAppName `
        --resource-group $ResourceGroup `
        --server $acrLoginServer `
        --identity $identityResourceId `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az containerapp registry set failed (exit $LASTEXITCODE)" }
}

# -----------------------------------------------------------------------------
# Step 5: pin the ingress idle timeout to 4 minutes (240s)
# -----------------------------------------------------------------------------

# Container Apps' HTTP request idle timeout is `ingress.idleTimeoutInMinutes`.
# 4 minutes = 240s, which matches the Seed's synchronous-blocking AC. The
# platform default already caps at 240s, but pinning the value explicitly:
#   • makes the configuration auditable (visible in `az containerapp show`),
#   • survives any future platform default change without a silent regression,
#   • mirrors the Seed's `request_timeout_seconds` ontology concept.
#
# `az containerapp ingress update --idle-timeout-in-minutes` has been the
# stable setter since the May-2024 CLI release. Older CLI versions silently
# ignore unknown flags and exit 2; we tolerate that by allowing the call to
# fail soft and warning the operator to upgrade if so.
Write-Host ">> Setting ingress idle timeout to 4 minutes (240s)..."
az containerapp ingress update `
    --name $ContainerAppName `
    --resource-group $ResourceGroup `
    --idle-timeout-in-minutes 4 `
    --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "ingress idle-timeout setter unavailable on this az version — the platform default of 240s still applies; upgrade az to silence this notice."
    # Reset $LASTEXITCODE so the next az call's exit-code check isn't poisoned.
    $global:LASTEXITCODE = 0
}

# -----------------------------------------------------------------------------
# Step 6: surface the public FQDN and next-step commands
# -----------------------------------------------------------------------------

$appFqdn = az containerapp show `
    --name $ContainerAppName `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.fqdn `
    --output tsv

Write-Host ""
Write-Host ">> Container App provisioning complete."
Write-Host "   Container App:   $ContainerAppName"
Write-Host "   Resource group:  $ResourceGroup"
Write-Host "   Environment:     $ContainerAppsEnv"
Write-Host "   Image:           $imageRef"
Write-Host "   UAMI clientId:   $identityClientId"
Write-Host "   Public FQDN:     https://$appFqdn"
Write-Host ""
Write-Host "   Next steps:"
Write-Host ""
Write-Host "   # 1. Wire the Container Apps secrets (DEEPSEEK_API_KEY + CLAURST_API_KEY)."
Write-Host "   #    Required before the first request — the binary refuses to start"
Write-Host "   #    without them."
Write-Host "   ./deploy/secrets/setup-secrets.ps1 ``"
Write-Host "     -ResourceGroup    $ResourceGroup ``"
Write-Host "     -ContainerApp     $ContainerAppName ``"
Write-Host "     -DeepseekApiKey   sk-... ``"
Write-Host "     -ClaurstApiKey    (\$([Guid]::NewGuid()).ToString())"
Write-Host ""
Write-Host "   # 2. Smoke-test the endpoint:"
Write-Host "   curl -sSf -X POST https://$appFqdn/ask ``"
Write-Host "     -H `"X-API-Key: `$env:CLAURST_API_KEY`" ``"
Write-Host "     -H 'Content-Type: application/json' ``"
Write-Host "     -d '{`"question`":`"What is the capital of France?`"}'"
Write-Host ""
Write-Host "   # 3. Tail logs:"
Write-Host "   az containerapp logs show ``"
Write-Host "     --name $ContainerAppName ``"
Write-Host "     --resource-group $ResourceGroup ``"
Write-Host "     --follow"
Write-Host ""
