// =============================================================================
// acr.bicep — Azure Container Registry for the claurst-ask REST endpoint.
// =============================================================================
//
// This template provisions the single ACR that hosts the `claude-code` runtime
// image (built from the repo-root Dockerfile). The image is later consumed by
// the Container Apps revision that runs `claude serve` and exposes POST /ask.
//
// Deploy with the Azure CLI from the repo root:
//
//   az deployment group create \
//     --resource-group rg-claurst \
//     --template-file deploy/acr.bicep \
//     --parameters registryName=claurstacr<unique>
//
// The output `loginServer` is the FQDN (`<name>.azurecr.io`) used as the image
// reference prefix when pushing from CI and pulling from Container Apps. The
// output `adminUsername` together with `az acr credential show` gives the pull
// credentials the Container Apps revision needs — see deploy/secrets/ for how
// those are wired into the running app.
//
// Why this is the only IaC artifact:
//   The seed constraints intentionally avoid IaC for the Container App itself
//   (single revision, manual `az containerapp` calls keep the deployment loop
//   tight). The registry, however, is a one-time provision — declaring it in
//   Bicep makes the SKU and admin-user posture auditable in source control
//   without adding a recurring template-update step to the deploy workflow.

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('''Globally-unique ACR name. Must be 5-50 characters, alphanumeric
only (no hyphens), and unique across all of Azure since it forms the
`<name>.azurecr.io` login server hostname.''')
@minLength(5)
@maxLength(50)
param registryName string

@description('Azure region for the registry. Defaults to the resource group region so the registry sits next to the Container App that pulls from it (avoids cross-region pull latency on cold starts).')
param location string = resourceGroup().location

@description('''Registry SKU. `Basic` is sufficient for the low/internal traffic
profile of this endpoint (10 GiB included storage, single webhook, no geo-
replication). Promote to `Standard` only if image size grows past ~10 GiB or
multiple regions need pull access; `Premium` is reserved for geo-replication,
private endpoints, and content trust — none of which apply here.''')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param sku string = 'Basic'

@description('''Enable the admin user account. Required because the Container
App pulls images using `--registry-server`/`--registry-username`/`--registry-
password` — the simplest auth path that fits the seed's "no Key Vault, no
managed identity beyond what Container Apps gives us" constraint. The admin
credentials are stored as Container Apps secrets (see deploy/secrets/ for the
analogous pattern used for DEEPSEEK_API_KEY and CLAURST_API_KEY).''')
param adminUserEnabled bool = true

@description('Optional tags applied to the registry for cost reporting / ownership tracking.')
param tags object = {
  workload: 'claurst-ask'
  component: 'container-registry'
}

// -----------------------------------------------------------------------------
// Resources
// -----------------------------------------------------------------------------

// API version 2023-07-01 is the latest GA at the time of authoring and supports
// every property used below. Newer previews aren't required — the registry has
// no advanced networking or policy features in this deployment.
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    // Admin user is the username/password pair Container Apps will consume.
    // See parameter docstring above for the rationale; flip to `false` only if
    // a downstream AC introduces managed-identity-based pulls.
    adminUserEnabled: adminUserEnabled

    // Public network access stays enabled: Container Apps' managed environment
    // pulls over the public registry endpoint. Locking this down would require
    // Premium SKU + a private endpoint, which the seed constraints forbid.
    publicNetworkAccess: 'Enabled'
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

@description('Fully-qualified login server, e.g. claurstacr123.azurecr.io. Use this as the image prefix when pushing from CI (`docker push <loginServer>/claurst-ask:<tag>`) and as `--registry-server` when configuring the Container App.')
output loginServer string = registry.properties.loginServer

@description('Resource ID of the registry — useful when later commands need to reference it (role assignments, diagnostic settings, etc.).')
output registryId string = registry.id

@description('Admin username (equals the registry name when admin user is enabled). Pair with the password retrieved via `az acr credential show -n <registryName>` to authenticate Container Apps to the registry.')
output adminUsername string = registry.name
