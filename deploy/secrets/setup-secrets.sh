#!/usr/bin/env bash
# setup-secrets.sh — configure Container Apps secrets and inject them as env vars.
#
# Satisfies AC 7: DEEPSEEK_API_KEY and the inbound X-API-Key are stored as
# Azure Container Apps secrets and surfaced to the running container as
# environment variables. No Bicep, no Terraform — direct `az` CLI only.
#
# Secret-name -> env-var mapping (lowercase-hyphenated is the Azure convention
# for secret names; UPPER_SNAKE for env vars consumed by the Rust binary):
#   deepseek-api-key  ->  DEEPSEEK_API_KEY    (used by cc-api to call DeepSeek)
#   claurst-api-key   ->  CLAURST_API_KEY     (compared against X-API-Key header)
#
# Required env vars when running this script:
#   AZ_RESOURCE_GROUP    Resource group containing the Container App
#   AZ_CONTAINERAPP      Name of the Container App (e.g. claurst-ask)
#   DEEPSEEK_API_KEY     Outbound key for DeepSeek's Anthropic-compatible API
#   CLAURST_API_KEY      Inbound shared secret callers send as X-API-Key
#
# Usage:
#   AZ_RESOURCE_GROUP=rg-claurst \
#   AZ_CONTAINERAPP=claurst-ask \
#   DEEPSEEK_API_KEY=sk-... \
#   CLAURST_API_KEY=$(openssl rand -hex 32) \
#   ./setup-secrets.sh

set -euo pipefail

: "${AZ_RESOURCE_GROUP:?AZ_RESOURCE_GROUP must be set}"
: "${AZ_CONTAINERAPP:?AZ_CONTAINERAPP must be set}"
: "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY must be set}"
: "${CLAURST_API_KEY:?CLAURST_API_KEY must be set}"

if ! command -v az >/dev/null 2>&1; then
  echo "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI" >&2
  exit 1
fi

echo ">> Storing secrets on Container App '${AZ_CONTAINERAPP}' in '${AZ_RESOURCE_GROUP}'..."
az containerapp secret set \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --secrets \
    "deepseek-api-key=${DEEPSEEK_API_KEY}" \
    "claurst-api-key=${CLAURST_API_KEY}" \
  --output none

echo ">> Binding secrets to environment variables on the running container..."
# `--set-env-vars` with the `secretref:` prefix tells Container Apps to resolve
# the value from the secret store at container start, never logging the literal.
# The trailing variables remain whatever the previous revision had (this command
# replaces only the listed names).
az containerapp update \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --set-env-vars \
    "DEEPSEEK_API_KEY=secretref:deepseek-api-key" \
    "CLAURST_API_KEY=secretref:claurst-api-key" \
  --output none

echo ">> Verifying configuration..."
az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query "{secrets: properties.configuration.secrets[].name, env: properties.template.containers[0].env[?name=='DEEPSEEK_API_KEY' || name=='CLAURST_API_KEY']}" \
  --output table

echo ">> Done. Secret values are not echoed; verify with:"
echo "   az containerapp revision list -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} -o table"
