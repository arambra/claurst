# setup-secrets.ps1 — configure Container Apps secrets and inject them as env vars.
#
# PowerShell 7+ counterpart to setup-secrets.sh. Satisfies AC 7: stores both
# DEEPSEEK_API_KEY and the inbound X-API-Key as Azure Container Apps secrets,
# then binds them to environment variables on the running container via
# `secretref:` indirection. Direct `az` CLI only — no Bicep, no Terraform.
#
# Secret-name -> env-var mapping:
#   deepseek-api-key  ->  DEEPSEEK_API_KEY    (cc-api outbound to DeepSeek)
#   claurst-api-key   ->  CLAURST_API_KEY     (compared against X-API-Key header)
#
# Required parameters (positional or named):
#   -ResourceGroup     Resource group containing the Container App
#   -ContainerApp      Name of the Container App (e.g. claurst-ask)
#   -DeepseekApiKey    Outbound key for DeepSeek's Anthropic-compatible API
#   -ClaurstApiKey     Inbound shared secret callers send as X-API-Key
#
# Example:
#   $deepseek = Read-Host -AsSecureString "DeepSeek key"
#   $inbound  = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
#   ./setup-secrets.ps1 -ResourceGroup rg-claurst -ContainerApp claurst-ask `
#                       -DeepseekApiKey (ConvertFrom-SecureString $deepseek -AsPlainText) `
#                       -ClaurstApiKey  $inbound

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,
    [Parameter(Mandatory = $true)] [string] $ContainerApp,
    [Parameter(Mandatory = $true)] [string] $DeepseekApiKey,
    [Parameter(Mandatory = $true)] [string] $ClaurstApiKey
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI"
}

Write-Host ">> Storing secrets on Container App '$ContainerApp' in '$ResourceGroup'..."
az containerapp secret set `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --secrets `
        "deepseek-api-key=$DeepseekApiKey" `
        "claurst-api-key=$ClaurstApiKey" `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az containerapp secret set failed (exit $LASTEXITCODE)" }

Write-Host ">> Binding secrets to environment variables on the running container..."
# `secretref:` indirection resolves the value from the secret store at start;
# the literal never appears in revision JSON or logs.
az containerapp update `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --set-env-vars `
        "DEEPSEEK_API_KEY=secretref:deepseek-api-key" `
        "CLAURST_API_KEY=secretref:claurst-api-key" `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az containerapp update failed (exit $LASTEXITCODE)" }

Write-Host ">> Verifying configuration..."
az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query "{secrets: properties.configuration.secrets[].name, env: properties.template.containers[0].env[?name=='DEEPSEEK_API_KEY' || name=='CLAURST_API_KEY']}" `
    --output table

Write-Host ">> Done. Secret values are not echoed. Inspect revisions with:"
Write-Host "   az containerapp revision list -n $ContainerApp -g $ResourceGroup -o table"
