# provision-acr.ps1 — create the resource group and deploy acr.bicep.
#
# PowerShell 7+ counterpart to provision-acr.sh. Satisfies Sub-AC 3.2: takes the
# deploy/acr.bicep template from source control and lands a real Azure
# Container Registry that the Container Apps revision (running `claude serve`)
# will pull the runtime image from. Direct `az` CLI only — no Terraform, no
# `azd`, no separate IaC orchestrator.
#
# What this script does, in order:
#   1. Confirms `az` is installed and the caller is logged in (`az account show`).
#   2. Creates the resource group if it does not already exist (idempotent).
#   3. Deploys deploy/acr.bicep into that group with the supplied registry name.
#   4. Captures the deployment outputs (loginServer, adminUsername) and prints
#      the next-step `docker push` / `az containerapp create` commands wired to
#      those values, so the operator can copy/paste straight into the next AC.
#
# Required parameters (positional or named):
#   -ResourceGroup    Resource group to create / deploy into (default: FGF-EDI-SANDBOX)
#   -Location         Azure region for the group + registry (default: canadacentral)
#   -AcrName          Globally-unique registry name, 5-50 alphanumerics only
#                     (forms <AcrName>.azurecr.io). Default: mapagentacr.
#                     ACR names disallow hyphens, so 'map-agent-acr' becomes 'mapagentacr'.
#
# Optional parameters:
#   -Sku              Basic | Standard | Premium  (default: Basic)
#   -DeploymentName   Name for the ARM deployment record (default: acr-<timestamp>)
#
# Example:
#   ./deploy/provision-acr.ps1
#   # (uses defaults: -ResourceGroup FGF-EDI-SANDBOX, -Location canadacentral,
#   #                 -AcrName mapagentacr)
#
#   # Or override the registry name (alphanumeric only, no hyphens):
#   ./deploy/provision-acr.ps1 -AcrName mapagentacrdev
#
# Re-running the script with the same inputs is safe: `az group create` and
# `az deployment group create` are both idempotent — the deployment will produce
# a no-op change set if nothing in acr.bicep has changed.

[CmdletBinding()]
param(
    [string] $ResourceGroup = 'FGF-EDI-SANDBOX',
    [string] $Location      = 'canadacentral',

    # ValidatePattern mirrors the Bicep @minLength/@maxLength constraints and
    # ACR's "alphanumeric only" rule. Catching this client-side avoids a
    # 5-second round-trip to ARM just to learn the name is invalid.
    [ValidatePattern('^[a-zA-Z0-9]{5,50}$')]
    [string] $AcrName = 'mapagentacr',

    [ValidateSet('Basic', 'Standard', 'Premium')]
    [string] $Sku = 'Basic',

    [string] $DeploymentName = "acr-$(Get-Date -Format 'yyyyMMddHHmmss' -AsUTC)"
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Locate the Bicep template relative to this script
# -----------------------------------------------------------------------------

# $PSScriptRoot resolves to the directory containing this .ps1, so the operator
# can invoke it from any working directory and still find acr.bicep.
$TemplateFile = Join-Path $PSScriptRoot 'acr.bicep'
if (-not (Test-Path -LiteralPath $TemplateFile)) {
    throw "Bicep template not found at $TemplateFile"
}

# -----------------------------------------------------------------------------
# Preflight: az CLI present and authenticated
# -----------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI"
}

# `az account show` exits non-zero when the caller is not logged in. Surfacing
# the active subscription up front gives the operator a chance to catch a
# wrong-subscription mistake before the deployment lands real money.
$null = az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first."
}

$subscriptionName = az account show --query name --output tsv
$subscriptionId   = az account show --query id   --output tsv

Write-Host ">> Active subscription: $subscriptionName ($subscriptionId)"
Write-Host ">> Target resource group: $ResourceGroup ($Location)"
Write-Host ">> Registry: $AcrName [SKU=$Sku]"

# -----------------------------------------------------------------------------
# Step 1: verify the resource group already exists
# -----------------------------------------------------------------------------

# FGF-EDI-SANDBOX (the default) is provisioned out-of-band by the platform team,
# so this script does NOT create resource groups. We only confirm the target
# group is reachable from the active subscription before deploying into it —
# this catches typos and wrong-subscription mistakes before the Bicep deployment
# fails 30+ seconds later with a less obvious error.
Write-Host ">> Verifying resource group exists..."
az group show --name $ResourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Resource group '$ResourceGroup' not found in subscription '$subscriptionName'. Confirm the name (case-sensitive) and that you're on the right subscription, or have the platform team provision it."
}

# -----------------------------------------------------------------------------
# Step 2: deploy the ACR Bicep template
# -----------------------------------------------------------------------------

Write-Host ">> Deploying $TemplateFile as deployment '$DeploymentName'..."
# `--output none` keeps the noisy ARM JSON off the console; we re-query the
# outputs below so the summary block is the script's only "look here" output.
az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $TemplateFile `
    --parameters `
        "registryName=$AcrName" `
        "location=$Location" `
        "sku=$Sku" `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az deployment group create failed (exit $LASTEXITCODE)" }

# Pull outputs out of the deployment record. The Bicep file declares
# `loginServer`, `registryId`, and `adminUsername` as outputs; we surface the
# two the operator actually copy/pastes into the next step.
$loginServer = az deployment group show `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --query 'properties.outputs.loginServer.value' `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az deployment group show (loginServer) failed (exit $LASTEXITCODE)" }

$adminUsername = az deployment group show `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --query 'properties.outputs.adminUsername.value' `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az deployment group show (adminUsername) failed (exit $LASTEXITCODE)" }

# -----------------------------------------------------------------------------
# Step 3: surface the next-step commands using the deployment outputs
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> ACR provisioning complete."
Write-Host "   Login server: $loginServer"
Write-Host "   Admin user:   $adminUsername"
Write-Host ""
Write-Host "   Next steps (copy/paste, then fill in <tag> and <containerapp>):"
Write-Host ""
Write-Host "   # 1. Build & push the image to the new registry:"
Write-Host "   az acr login --name $AcrName"
Write-Host "   docker build -t $loginServer/map-agent:<tag> ."
Write-Host "   docker push $loginServer/map-agent:<tag>"
Write-Host ""
Write-Host "   # 2. Retrieve the admin password (for Container Apps registry auth):"
Write-Host "   az acr credential show --name $AcrName --query 'passwords[0].value' -o tsv"
Write-Host ""
Write-Host "   # 3. Wire the registry into a Container App revision:"
Write-Host "   az containerapp create ``"
Write-Host "     --name <containerapp> ``"
Write-Host "     --resource-group $ResourceGroup ``"
Write-Host "     --image $loginServer/map-agent:<tag> ``"
Write-Host "     --registry-server $loginServer ``"
Write-Host "     --registry-username $adminUsername ``"
Write-Host "     --registry-password '<paste-from-step-2>'"
Write-Host ""
