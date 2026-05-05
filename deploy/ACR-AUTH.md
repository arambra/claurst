# ACR Authentication (Local & CI)

This document covers Sub-AC 3.3 of the deployment seed: how a developer
workstation or a CI runner authenticates to the Azure Container Registry that
`provision-acr.ps1` stood up, so that subsequent `docker push` /
`docker build --push` commands can land the `claurst-ask` image in ACR.

The entire flow is `az acr login` plus optional service-principal handling —
no managed identity, no Key Vault, nothing the seed's "no IaC for the app
itself" constraint would forbid.

## When you need this

| Step                       | Auth required?                 | Script                            |
| -------------------------- | ------------------------------ | --------------------------------- |
| Provision the ACR (once)   | `az login` (Owner / Contrib.)  | `provision-acr.ps1`               |
| Configure secrets          | `az login` (Container App RW)  | `secrets/setup-secrets.ps1`       |
| **Push an image to ACR**   | **`az acr login` (this doc)**  | **`acr-login.ps1`**               |
| Container App pulls image  | UAMI (AcrPull) or admin creds  | n/a — Container Apps does this    |

The push step is the only one that needs registry-scoped auth: ARM permissions
get you to `az deployment group create`, but Docker's HTTPS push protocol talks
to `<acr>.azurecr.io` directly and needs a token specific to that registry.

## Two supported flows

### 1. Local interactive (developer workstation)

Prereqs:
- `az` CLI installed (https://aka.ms/InstallAzureCLI)
- `docker` daemon running (Docker Desktop, Colima, OrbStack, etc.)
- Already authenticated with `az login` to the subscription that owns the ACR

```powershell
# PowerShell 7+ — Windows, Linux (pwsh), macOS (pwsh)
./deploy/acr-login.ps1 -AcrName claurstacr1a2b3c
```

Under the hood `az acr login` mints a short-lived AAD-backed token (~3 hour
lifetime), then writes it into Docker's credential helper for the
`<acr>.azurecr.io` host. Subsequent `docker push <acr>.azurecr.io/...` calls
re-use that stored credential transparently.

Re-run the script any time pushes start failing with `unauthorized` — it is
idempotent and just refreshes the token in place.

### 2. CI / headless (service principal)

Provision a service principal once with **AcrPush** (or higher) on the
registry's resource ID. The minimal scope keeps the SP from accidentally
gaining permissions to anything else in the subscription:

```bash
# One-time, run by an Owner on a workstation:
ACR_ID=$(az acr show -n claurstacr1a2b3c --query id -o tsv)

az ad sp create-for-rbac \
  --name  sp-claurst-ask-ci \
  --role  AcrPush \
  --scopes "$ACR_ID" \
  --years 1
# -> { "appId": "...", "password": "...", "tenant": "..." }
```

Store `appId`, `password`, and `tenant` as CI secrets (GitHub Actions, Azure
DevOps, GitLab CI, etc.) named `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`,
`AZURE_TENANT_ID`. The login script picks them up from explicit args or env
vars:

```powershell
# Linux/macOS CI runners have pwsh pre-installed on most images
pwsh ./deploy/acr-login.ps1 `
  -AcrName      claurstacr1a2b3c `
  -ClientId     $env:AZURE_CLIENT_ID `
  -ClientSecret $env:AZURE_CLIENT_SECRET `
  -TenantId     $env:AZURE_TENANT_ID
```

The script first runs `az login --service-principal --username ... --password
... --tenant ...` (silenced — we don't want subscription JSON in CI logs),
then issues the same `az acr login --name ...` as the local flow.

#### GitHub Actions snippet

`push-image.ps1` calls `acr-login.ps1` internally and pushes both the
rolling `:latest` and the immutable `:vMAJOR.MINOR.PATCH` tags, so a CI job
can collapse build/auth/push into two steps:

```yaml
- name: Build image
  shell: pwsh
  run: ./deploy/build-image.ps1 -AcrName ${{ secrets.ACR_NAME }} -ImageVersion v${{ github.run_number }}.0.0

- name: Push image to ACR
  shell: pwsh
  env:
    AZURE_CLIENT_ID:     ${{ secrets.AZURE_CLIENT_ID }}
    AZURE_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
    AZURE_TENANT_ID:     ${{ secrets.AZURE_TENANT_ID }}
  run: ./deploy/push-image.ps1 -AcrName ${{ secrets.ACR_NAME }} -ImageVersion v${{ github.run_number }}.0.0
```

If you'd rather invoke the auth and push steps separately (e.g. to push a
one-off ad-hoc tag that doesn't go through `build-image.ps1`), the lower-level
flow still works:

```yaml
- name: Authenticate to ACR
  shell: pwsh
  env:
    AZURE_CLIENT_ID:     ${{ secrets.AZURE_CLIENT_ID }}
    AZURE_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
    AZURE_TENANT_ID:     ${{ secrets.AZURE_TENANT_ID }}
  run: ./deploy/acr-login.ps1 -AcrName ${{ secrets.ACR_NAME }}

- name: Build & push image (ad-hoc tag)
  run: |
    docker build -t "${{ secrets.ACR_NAME }}.azurecr.io/claurst-ask:${{ github.sha }}" .
    docker push      "${{ secrets.ACR_NAME }}.azurecr.io/claurst-ask:${{ github.sha }}"
```

### Daemonless builders (kaniko, buildah, oras)

Some build environments (devcontainers without DinD, restricted CI runners,
`gcr.io/kaniko-project/executor`) cannot run a Docker daemon. They speak the
OCI registry HTTP API directly and accept a registry token instead of a
credential-helper entry. Run the login script in `token` mode and capture the
token to a file the builder can read:

```powershell
./deploy/acr-login.ps1 -AcrName claurstacr1a2b3c -Mode Token > token.txt

# kaniko example: --registry-token=$(Get-Content token.txt)
# buildah example: buildah login --username 00000000-0000-0000-0000-000000000000 `
#                                --password (Get-Content token.txt) `
#                                claurstacr1a2b3c.azurecr.io
```

The username paired with this token is always the literal GUID
`00000000-0000-0000-0000-000000000000` (an ACR convention for token-based
auth). Token lifetime is ~3 hours.

## Troubleshooting

| Symptom                                                          | Likely cause                                                | Fix                                                                       |
| ---------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------- |
| `az: command not found` / `az not recognized`                    | Azure CLI not installed                                     | https://aka.ms/InstallAzureCLI                                            |
| `Not logged in to Azure.`                                        | No active `az` session                                      | Run `az login` (interactive) or set `AZURE_CLIENT_*` env vars (CI flow)   |
| `unauthorized: authentication required` on `docker push`         | Token expired (>3h since `az acr login`) or wrong registry  | Re-run `./deploy/acr-login.ps1`                                           |
| `denied: requested access to the resource is denied`             | SP lacks `AcrPush` on this registry                         | Re-run `az role assignment create --role AcrPush --assignee <appId> ...`  |
| `Cannot connect to the Docker daemon`                            | Docker not running, or you're on a daemonless build runner  | Start Docker, or use `ACR_LOGIN_MODE=token` / `-Mode Token`               |
| `'<acr>' is not a valid Azure container registry name`           | Passed `<acr>.azurecr.io` instead of `<acr>`                | Strip the `.azurecr.io` suffix — the script appends it where needed       |

## Runtime pull vs CI push

**Pull (Container App → ACR).** The Container App pulls images via the
user-assigned managed identity `mapagentid`, provided that identity holds
the `AcrPull` role on the registry. Granting `AcrPull` requires
`Microsoft.Authorization/roleAssignments/write` (Owner or User Access
Administrator). If the deployer has only Contributor, the role grant fails;
in that case fall back to ACR admin credentials, which `acr.bicep` already
enables (`adminUserEnabled: true`):

```powershell
$u = az acr credential show -n $acr -g $rg --query username -o tsv
$p = az acr credential show -n $acr -g $rg --query 'passwords[0].value' -o tsv
az containerapp registry set -n claurst-ask -g $rg --server "$acr.azurecr.io" --username $u --password $p
```

`provision-app.ps1` detects an admin/token registry binding and skips its
UAMI rebind to avoid a 15-25 min platform retry hang when the UAMI lacks
`AcrPull`.

**Push (CI → ACR).** Push uses a dedicated `AcrPush` service principal
(scoped to one registry), not the runtime credentials. A compromised CI
token can therefore overwrite tags but cannot delete the registry, read the
admin password, or touch the Container App. Local dev pushes use the
operator's interactive `az login` token via `acr-login.ps1`.
