# provision-identity.ps1 — create a user-assigned managed identity (UAMI) and
# grant it AcrPull on the target Azure Container Registry.
#
# PowerShell 7+ counterpart to provision-identity.sh. Satisfies AC 40101
# Sub-AC 1: lands the identity the Container Apps revision will use to pull
# the runtime image from ACR — eliminating the need to ship the registry's
# admin password as a Container Apps secret. Direct `az` CLI only — no Bicep,
# no Terraform, no `azd`. The Seed forbids IaC for anything beyond the
# pre-existing ACR template.
#
# Why a UAMI (and not the ACR admin user / a system-assigned identity)?
#   • UAMI lifecycle is independent of the Container App: we can roll the app
#     image, recreate the revision, or even delete the app, and the identity +
#     its role assignment survive. That keeps Sub-AC 2 (wiring the identity
#     into `az containerapp create`) and Sub-AC 3 (granting access) cleanly
#     decoupled from the workload's lifecycle.
#   • UAMI gets an explicit principalId we can role-assign here, before the
#     Container App exists. A system-assigned identity would force us to
#     create the app first, then bolt the role on after — fragile and harder
#     to make idempotent.
#   • Avoids storing ACR admin credentials in Container Apps secrets, which
#     the Seed's "no Key Vault" + "secrets-only-for-DeepSeek/X-API-Key"
#     posture would otherwise require.
#
# What this script does, in order:
#   1. Confirms `az` is installed and the caller is logged in (`az account show`).
#   2. Ensures the resource group exists (idempotent — same pattern as
#      provision-acr.ps1 and provision-env.ps1).
#   3. Creates the user-assigned managed identity if it doesn't already exist.
#   4. Resolves the ACR resource ID and the UAMI principalId.
#   5. Grants the UAMI the built-in `AcrPull` role (scope = the ACR), guarded
#      by an existence check so re-runs are no-ops.
#   6. Prints the identity resource ID + clientId + principalId, plus the
#      next-step `az containerapp create` snippet wired to those values.
#
# Required parameters (positional or named):
#   -ResourceGroup       Resource group to deploy into (default: FGF-EDI-SANDBOX).
#                        The group is provisioned out-of-band; this script verifies
#                        it exists rather than creating it. Should match the group
#                        used by provision-acr.ps1 / provision-env.ps1 so the
#                        registry, environment, identity, and container app live
#                        together.
#   -Location            Azure region for the group + identity
#                        (default: canadacentral). UAMIs are regional; pin them
#                        to the same region as the Container Apps environment
#                        to avoid cross-region calls on every image pull.
#   -IdentityName        Name for the user-assigned managed identity
#                        (default: mapagentid). 3-128 chars, alphanumerics +
#                        hyphens / underscores; must start with a letter or
#                        digit.
#   -AcrName             Name of the existing Azure Container Registry that the
#                        identity needs AcrPull on (default: mapagentacr). Must
#                        be a registry already provisioned by
#                        deploy/provision-acr.ps1; we resolve its resourceId by
#                        name rather than asking the operator to paste it.
#
# Optional parameters:
#   -AcrResourceGroup    Resource group containing the ACR if different from
#                        -ResourceGroup (defaults to -ResourceGroup). Useful if
#                        the registry is shared across environments and lives
#                        in a separate "platform" group.
#
# Example:
#   ./deploy/provision-identity.ps1
#   # (uses defaults: -ResourceGroup FGF-EDI-SANDBOX, -Location canadacentral,
#   #                 -IdentityName mapagentid, -AcrName mapagentacr)
#
# Re-running the script with the same inputs is safe at every step: the
# identity create call returns the existing record if the name is taken in the
# group, and the role-assignment block is guarded by an existence check.

[CmdletBinding()]
param(
    [string] $ResourceGroup = 'FGF-EDI-SANDBOX',
    [string] $Location      = 'canadacentral',

    # ValidatePattern mirrors the ARM rules for managed-identity names:
    # 3-128 chars, alphanumeric / hyphen / underscore, must start with a
    # letter or digit. Catching this client-side avoids a 5-second round-trip
    # to ARM just to learn the name is invalid.
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{2,127}$')]
    [string] $IdentityName = 'mapagentid',

    # Mirror the ACR name validation from provision-acr.ps1 so a typo here
    # gets caught locally instead of as a 404 from `az acr show`.
    [ValidatePattern('^[a-zA-Z0-9]{5,50}$')]
    [string] $AcrName = 'mapagentacr',

    [string] $AcrResourceGroup = ''
)

$ErrorActionPreference = 'Stop'

# Default the ACR group to the workload group if the operator didn't pass one.
# Done after param() so we have access to $ResourceGroup as the fallback.
if ([string]::IsNullOrWhiteSpace($AcrResourceGroup)) {
    $AcrResourceGroup = $ResourceGroup
}

# -----------------------------------------------------------------------------
# Preflight: az CLI present and authenticated
# -----------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI"
}

# `az account show` exits non-zero when the caller is not logged in. Surfacing
# the active subscription up front gives the operator a chance to catch a
# wrong-subscription mistake before the role assignment lands.
$null = az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first."
}

$subscriptionName = az account show --query name --output tsv
$subscriptionId   = az account show --query id   --output tsv

Write-Host ">> Active subscription: $subscriptionName ($subscriptionId)"
Write-Host ">> Target resource group: $ResourceGroup ($Location)"
Write-Host ">> Identity:              $IdentityName"
Write-Host ">> Registry:              $AcrName (group: $AcrResourceGroup)"

# -----------------------------------------------------------------------------
# Step 0: ensure resource provider is registered
# -----------------------------------------------------------------------------

# `Microsoft.ManagedIdentity` is the RP for user-assigned identities. Usually
# pre-registered, but a fresh subscription will silently 404 the create call
# below if it isn't. Register first — it's a no-op if already registered.
Write-Host ">> Ensuring Microsoft.ManagedIdentity provider is registered..."
az provider register --namespace Microsoft.ManagedIdentity --wait --output none
if ($LASTEXITCODE -ne 0) { throw "az provider register failed (exit $LASTEXITCODE)" }

# -----------------------------------------------------------------------------
# Step 1: verify the resource group already exists
# -----------------------------------------------------------------------------

# FGF-EDI-SANDBOX (the default) is provisioned out-of-band by the platform team,
# so this script does NOT create resource groups. We only confirm the target
# group is reachable from the active subscription before deploying into it.
Write-Host ">> Verifying resource group exists..."
az group show --name $ResourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Resource group '$ResourceGroup' not found in subscription '$subscriptionName'. Confirm the name (case-sensitive) and that you're on the right subscription, or have the platform team provision it."
}

# -----------------------------------------------------------------------------
# Step 2: ensure the user-assigned managed identity exists
# -----------------------------------------------------------------------------

# `az identity create` returns the existing identity (and exits 0) when an
# identity with the same name already exists in the group, so the call is
# safely idempotent.
Write-Host ">> Ensuring user-assigned managed identity '$IdentityName' exists..."
az identity create `
    --name $IdentityName `
    --resource-group $ResourceGroup `
    --location $Location `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az identity create failed (exit $LASTEXITCODE)" }

# Re-query for a canonical, machine-readable view. We want three fields:
#   • principalId  — the AAD object ID we role-assign in step 4
#   • clientId     — the OAuth client ID the running container will federate as
#   • id           — the ARM resource ID we hand to `az containerapp create
#                    --user-assigned` and `--registry-identity` in Sub-AC 2
$identityPrincipalId = az identity show `
    --name $IdentityName `
    --resource-group $ResourceGroup `
    --query principalId `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az identity show (principalId) failed (exit $LASTEXITCODE)" }

$identityClientId = az identity show `
    --name $IdentityName `
    --resource-group $ResourceGroup `
    --query clientId `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az identity show (clientId) failed (exit $LASTEXITCODE)" }

$identityResourceId = az identity show `
    --name $IdentityName `
    --resource-group $ResourceGroup `
    --query id `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az identity show (id) failed (exit $LASTEXITCODE)" }

if ([string]::IsNullOrWhiteSpace($identityPrincipalId) -or
    [string]::IsNullOrWhiteSpace($identityClientId) -or
    [string]::IsNullOrWhiteSpace($identityResourceId)) {
    throw "Failed to retrieve identity properties for '$IdentityName' — aborting."
}

# -----------------------------------------------------------------------------
# Step 3: resolve the target ACR's resource ID
# -----------------------------------------------------------------------------

# `az acr show` exits non-zero with a 404 when the registry doesn't exist.
# Surface that as a precise error rather than letting `az role assignment
# create` fail later with a generic "scope is invalid" message.
$acrResourceId = az acr show `
    --name $AcrName `
    --resource-group $AcrResourceGroup `
    --query id `
    --output tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrResourceId)) {
    throw "ACR '$AcrName' not found in resource group '$AcrResourceGroup'. Run deploy/provision-acr.ps1 first, or set -AcrResourceGroup if the registry lives in a different group."
}

# -----------------------------------------------------------------------------
# Step 4: grant the identity AcrPull on the registry (idempotent)
# -----------------------------------------------------------------------------

# Pre-flight existence check: `az role assignment list` filters by
# (assignee, role, scope). If the assignment already exists, skip the create
# call — `az role assignment create` is *not* fully idempotent on duplicates
# (it returns a 409 with a non-zero exit code, which would break re-runs).
#
# Note on `--assignee-object-id` + `--assignee-principal-type ServicePrincipal`:
# we use the principalId (AAD object ID) directly rather than the clientId.
# This avoids a Graph lookup that fails on freshly-created identities (the
# AAD propagation race). For a UAMI, principal-type is always ServicePrincipal.
Write-Host ">> Checking for existing AcrPull role assignment..."
$existingAssignmentId = az role assignment list `
    --assignee-object-id $identityPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role AcrPull `
    --scope $acrResourceId `
    --query '[0].id' `
    --output tsv 2>$null

if (-not [string]::IsNullOrWhiteSpace($existingAssignmentId)) {
    Write-Host ">> AcrPull already granted to '$IdentityName' on '$AcrName' — skipping."
}
else {
    Write-Host ">> Granting AcrPull on '$AcrName' to '$IdentityName'..."
    # Retry loop: AAD takes a few seconds to propagate a freshly-created UAMI's
    # principalId across the tenant. Without this, the first call after `az
    # identity create` can fail with "Principal does not exist in directory".
    # 5 retries × 6s = 30s ceiling, which is plenty for the typical 5-15s
    # propagation window.
    $attempts = 0
    $created = $false
    while (-not $created) {
        az role assignment create `
            --assignee-object-id $identityPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role AcrPull `
            --scope $acrResourceId `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            $created = $true
            break
        }

        $attempts++
        if ($attempts -ge 5) {
            Write-Warning "Failed to create AcrPull role assignment after $attempts attempts."
            # Re-run once without redirecting stderr so the operator sees the
            # underlying error (likely a permissions issue — Owner/RBAC Admin
            # needed on the ACR).
            az role assignment create `
                --assignee-object-id $identityPrincipalId `
                --assignee-principal-type ServicePrincipal `
                --role AcrPull `
                --scope $acrResourceId
            throw "az role assignment create failed (exit $LASTEXITCODE)"
        }
        Write-Host "   (attempt $attempts failed, retrying in 6s — likely AAD propagation delay)"
        Start-Sleep -Seconds 6
    }
}

# -----------------------------------------------------------------------------
# Step 5: surface the next-step commands using the identity outputs
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> Identity provisioning complete."
Write-Host "   Identity name:        $IdentityName"
Write-Host "   Resource ID:          $identityResourceId"
Write-Host "   Client ID:            $identityClientId"
Write-Host "   Principal ID:         $identityPrincipalId"
Write-Host "   AcrPull granted on:   $acrResourceId"
Write-Host ""
Write-Host "   Next step (Sub-AC 2 wires this identity into the Container App revision so"
Write-Host "   image pulls authenticate via the UAMI instead of admin credentials):"
Write-Host ""
Write-Host "   az containerapp create ``"
Write-Host "     --name claurst-ask ``"
Write-Host "     --resource-group $ResourceGroup ``"
Write-Host "     --environment <containerapp-env> ``"
Write-Host "     --image $AcrName.azurecr.io/claurst-ask:<tag> ``"
Write-Host "     --user-assigned $identityResourceId ``"
Write-Host "     --registry-server $AcrName.azurecr.io ``"
Write-Host "     --registry-identity $identityResourceId ``"
Write-Host "     --ingress external ``"
Write-Host "     --target-port 8080 ``"
Write-Host "     --min-replicas 1 ``"
Write-Host "     --max-replicas 1"
Write-Host ""
