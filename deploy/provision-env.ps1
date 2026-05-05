# provision-env.ps1 — create the resource group, Log Analytics workspace,
# and Azure Container Apps Environment that the `claude serve` revision
# will run in.
#
# PowerShell 7+ counterpart to provision-env.sh. Satisfies AC 5 Sub-AC 1:
# a single, idempotent script that lands the Container Apps managed
# environment (with its required Log Analytics workspace) in the target
# resource group + region. Direct `az` CLI only — no Bicep, no Terraform,
# no `azd`. The Seed explicitly forbids IaC for anything beyond the
# pre-existing ACR template.
#
# Resource hierarchy this script creates / ensures (idempotent at every step):
#   <ResourceGroup>          (resource group, region = Location)
#     ├── <LawName>          (Log Analytics workspace, PerGB2018 SKU)
#     └── <EnvironmentName>  (Container Apps managed environment, wired
#                             to the LAW for stdout/stderr → KQL queries)
#
# Why a Log Analytics workspace? Container Apps requires a destination for the
# environment-level diagnostic stream. Without it, `az containerapp env create`
# would either fail or silently default to a workspace it manages for you,
# which we cannot inspect or query later. Pinning the LAW name here lets the
# operator run `az monitor log-analytics query` against the
# `ContainerAppConsoleLogs_CL` table when the deployed `/ask` endpoint
# misbehaves.
#
# Required parameters (positional or named):
#   -ResourceGroup     Resource group to deploy into (default: FGF-EDI-SANDBOX).
#                      The group is provisioned out-of-band; this script verifies
#                      it exists rather than creating it. Should match the group
#                      used for provision-acr.ps1 so the registry, environment,
#                      and container app live together.
#   -Location          Azure region for the group, workspace, and environment
#                      (default: canadacentral). Must be a region where the
#                      Container Apps service is available — see
#                      https://aka.ms/containerapps-regions.
#   -EnvironmentName   Name for the managed environment (default: mapagentenv).
#                      2-32 chars, lowercase letters / digits / hyphens; the
#                      name appears as a DNS label so we validate that here.
#
# Optional parameters:
#   -LawName           Log Analytics workspace name. Default:
#                      "<EnvironmentName>-law". 4-63 chars, must start and
#                      end alphanumeric, hyphens allowed.
#
# Example:
#   ./deploy/provision-env.ps1
#   # (uses defaults: -ResourceGroup FGF-EDI-SANDBOX, -Location canadacentral,
#   #                 -EnvironmentName mapagentenv)
#
# Re-running the script with the same inputs is safe: every `az` call below
# is either inherently idempotent (`az group create`) or guarded by a
# pre-flight existence check.

[CmdletBinding()]
param(
    [string] $ResourceGroup = 'FGF-EDI-SANDBOX',
    [string] $Location      = 'canadacentral',

    # Container Apps environment names form part of the per-app DNS label
    # (<app>.<random>.<region>.azurecontainerapps.io). Validating client-side
    # avoids a 5-second round-trip to ARM just to learn the name is invalid.
    [ValidatePattern('^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$')]
    [string] $EnvironmentName = 'mapagentenv',

    # Log Analytics workspace name rules (per ARM spec): 4-63 chars,
    # alphanumeric or hyphen, must start and end alphanumeric.
    [ValidatePattern('^[a-zA-Z0-9]([-a-zA-Z0-9]{2,61}[a-zA-Z0-9])$')]
    [string] $LawName
)

$ErrorActionPreference = 'Stop'

# Default the workspace name to "<env>-law". The "-law" suffix follows the
# pattern Microsoft uses in their own quickstart docs and keeps the
# relationship obvious in the portal/CLI listing.
if (-not $LawName) {
    $LawName = "$EnvironmentName-law"
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
Write-Host ">> Container Apps environment: $EnvironmentName"
Write-Host ">> Log Analytics workspace:    $LawName"

# -----------------------------------------------------------------------------
# Step 0: resource provider registration & containerapp extension
# -----------------------------------------------------------------------------

# `Microsoft.App` is the RP for Container Apps; `Microsoft.OperationalInsights`
# is the RP for Log Analytics. Both are usually pre-registered on a mature
# subscription, but a fresh sub will silently 404 the create calls below if
# they aren't, with an opaque error. Register first — it's a no-op if already
# registered.
Write-Host ">> Ensuring Microsoft.App and Microsoft.OperationalInsights providers are registered..."
az provider register --namespace Microsoft.App --wait --output none
if ($LASTEXITCODE -ne 0) { throw "az provider register Microsoft.App failed (exit $LASTEXITCODE)" }
az provider register --namespace Microsoft.OperationalInsights --wait --output none
if ($LASTEXITCODE -ne 0) { throw "az provider register Microsoft.OperationalInsights failed (exit $LASTEXITCODE)" }

# `az containerapp env create` lives in the `containerapp` extension. Modern
# Azure CLI auto-installs on first use, but adding explicitly here makes the
# script work on older `az` versions too. We do a presence-check first so
# this step is idempotent and does not invoke pip when the extension is
# already installed (some Windows hosts have a corrupted bundled Python in
# the Azure CLI install where pip segfaults with 0xC0000005 on every add /
# upgrade — re-installing or upgrading on those hosts is impossible without
# repairing the CLI MSI, but a present-and-functional extension keeps
# working fine).
Write-Host ">> Ensuring 'containerapp' Azure CLI extension is installed..."
$installed = az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($installed)) {
    az extension add --name containerapp --only-show-errors --yes --output none
    if ($LASTEXITCODE -ne 0) { throw "az extension add containerapp failed (exit $LASTEXITCODE). If pip is crashing with 0xC0000005 on this host, see deploy/README troubleshooting for a manual wheel-extraction workaround." }
} else {
    Write-Host "   (already installed; skipping add/upgrade)"
}

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
# Step 2: ensure the Log Analytics workspace exists
# -----------------------------------------------------------------------------

# `az monitor log-analytics workspace create` returns the existing workspace
# (and exits 0) if a workspace with the same name already exists in the
# group. We pin the SKU to PerGB2018 — the only generally-available SKU
# since 2020 and the one assumed by `az containerapp env create` defaults.
Write-Host ">> Ensuring Log Analytics workspace '$LawName' exists..."
az monitor log-analytics workspace create `
    --resource-group $ResourceGroup `
    --workspace-name $LawName `
    --location $Location `
    --sku PerGB2018 `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az monitor log-analytics workspace create failed (exit $LASTEXITCODE)" }

# Pull the workspace identifiers the Container Apps environment needs to be
# wired to the LAW. `customerId` is the workspace GUID, `primarySharedKey`
# is the ingest key — both are required by `az containerapp env create
# --logs-workspace-{id,key}`.
$lawCustomerId = az monitor log-analytics workspace show `
    --resource-group $ResourceGroup `
    --workspace-name $LawName `
    --query customerId `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az monitor log-analytics workspace show failed (exit $LASTEXITCODE)" }

$lawSharedKey = az monitor log-analytics workspace get-shared-keys `
    --resource-group $ResourceGroup `
    --workspace-name $LawName `
    --query primarySharedKey `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az monitor log-analytics workspace get-shared-keys failed (exit $LASTEXITCODE)" }

if (-not $lawCustomerId -or -not $lawSharedKey) {
    throw "Failed to retrieve Log Analytics workspace credentials — aborting."
}

# -----------------------------------------------------------------------------
# Step 3: ensure the Container Apps managed environment exists
# -----------------------------------------------------------------------------

# Pre-flight check before issuing the create call: `az containerapp env show`
# exits non-zero when the environment doesn't exist. We use this to keep the
# "already created" path silent and avoid spurious error noise from the
# create command's overly chatty failure mode on duplicate names.
$existingEnvId = az containerapp env show `
    --name $EnvironmentName `
    --resource-group $ResourceGroup `
    --query id `
    --output tsv 2>$null

if ($existingEnvId) {
    Write-Host ">> Container Apps environment '$EnvironmentName' already exists — skipping create."
} else {
    Write-Host ">> Creating Container Apps environment '$EnvironmentName' (this can take a few minutes)..."
    az containerapp env create `
        --name $EnvironmentName `
        --resource-group $ResourceGroup `
        --location $Location `
        --logs-workspace-id $lawCustomerId `
        --logs-workspace-key $lawSharedKey `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az containerapp env create failed (exit $LASTEXITCODE)" }
}

# Re-query to surface a single canonical environment ID for the summary block.
$envId = az containerapp env show `
    --name $EnvironmentName `
    --resource-group $ResourceGroup `
    --query id `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az containerapp env show (id) failed (exit $LASTEXITCODE)" }

$envDefaultDomain = az containerapp env show `
    --name $EnvironmentName `
    --resource-group $ResourceGroup `
    --query properties.defaultDomain `
    --output tsv
if ($LASTEXITCODE -ne 0) { throw "az containerapp env show (defaultDomain) failed (exit $LASTEXITCODE)" }

# -----------------------------------------------------------------------------
# Step 4: surface the next-step commands for the operator
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> Container Apps environment provisioning complete."
Write-Host "   Environment ID:  $envId"
Write-Host "   Default domain:  $envDefaultDomain"
Write-Host "   Log Analytics:   $LawName (workspace ID $lawCustomerId)"
Write-Host ""
Write-Host "   Next steps (copy/paste, then fill in <acrname>, <tag>, registry-password):"
Write-Host ""
Write-Host "   # Wire the registry into a Container App revision inside this environment:"
Write-Host "   az containerapp create ``"
Write-Host "     --name claurst-ask ``"
Write-Host "     --resource-group $ResourceGroup ``"
Write-Host "     --environment $EnvironmentName ``"
Write-Host "     --image <acrname>.azurecr.io/claurst-ask:<tag> ``"
Write-Host "     --registry-server <acrname>.azurecr.io ``"
Write-Host "     --registry-username <acrname> ``"
Write-Host "     --registry-password '<paste-from-acr-credential-show>' ``"
Write-Host "     --ingress external ``"
Write-Host "     --target-port 8080 ``"
Write-Host "     --min-replicas 1 ``"
Write-Host "     --max-replicas 1"
Write-Host ""
Write-Host "   # Tail logs once the app is running:"
Write-Host "   az containerapp logs show ``"
Write-Host "     --name claurst-ask ``"
Write-Host "     --resource-group $ResourceGroup ``"
Write-Host "     --follow"
Write-Host ""
