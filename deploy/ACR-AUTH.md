# ACR Authentication (Local & CI)

This document covers Sub-AC 3.3 of the deployment seed: how a developer
workstation or a CI runner authenticates to the Azure Container Registry that
`provision-acr.{sh,ps1}` stood up, so that subsequent `docker push` /
`docker build --push` commands can land the `claurst-ask` image in ACR.

The entire flow is `az acr login` plus optional service-principal handling —
no managed identity, no Key Vault, nothing the seed's "no IaC for the app
itself" constraint would forbid.

## When you need this

| Step                       | Auth required?                 | Script                              |
| -------------------------- | ------------------------------ | ----------------------------------- |
| Provision the ACR (once)   | `az login` (Owner / Contrib.) | `provision-acr.{sh,ps1}`            |
| Configure secrets          | `az login` (Container App RW)  | `secrets/setup-secrets.{sh,ps1}`    |
| **Push an image to ACR**   | **`az acr login` (this doc)**  | **`acr-login.{sh,ps1}`**            |
| Container App pulls image  | Admin user creds (auto)        | n/a — Container Apps does this      |

The push step is the only one that needs registry-scoped auth: ARM permissions
get you to `az deployment group create`, but Docker's HTTPS push protocol talks
to `<acr>.azurecr.io` directly and needs a token specific to that registry.

## Two supported flows

### 1. Local interactive (developer workstation)

Prereqs:
- `az` CLI installed (https://aka.ms/InstallAzureCLI)
- `docker` daemon running (Docker Desktop, Colima, OrbStack, etc.)
- Already authenticated with `az login` to the subscription that owns the ACR

```bash
# Bash / WSL / macOS
ACR_NAME=claurstacr1a2b3c ./deploy/acr-login.sh
```

```powershell
# PowerShell 7+ on Windows
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
`AZURE_TENANT_ID`. The login script picks them up automatically:

```bash
# Bash CI step
ACR_NAME=claurstacr1a2b3c \
AZURE_CLIENT_ID="$AZURE_CLIENT_ID" \
AZURE_CLIENT_SECRET="$AZURE_CLIENT_SECRET" \
AZURE_TENANT_ID="$AZURE_TENANT_ID" \
./deploy/acr-login.sh
```

```powershell
# PowerShell CI step (env vars also accepted; these explicit args are equivalent)
./deploy/acr-login.ps1 `
  -AcrName      claurstacr1a2b3c `
  -ClientId     $env:AZURE_CLIENT_ID `
  -ClientSecret $env:AZURE_CLIENT_SECRET `
  -TenantId     $env:AZURE_TENANT_ID
```

The script first runs `az login --service-principal --username ... --password
... --tenant ...` (silenced — we don't want subscription JSON in CI logs),
then issues the same `az acr login --name ...` as the local flow.

#### GitHub Actions snippet

`push-image.sh` already calls `acr-login.sh` internally and pushes both the
rolling `:latest` and the immutable `:vMAJOR.MINOR.PATCH` tags, so a CI job
can collapse build/auth/push into two steps:

```yaml
- name: Build image
  env:
    ACR_NAME: ${{ secrets.ACR_NAME }}
  run: ./deploy/build-image.sh

- name: Push image to ACR
  env:
    ACR_NAME:            ${{ secrets.ACR_NAME }}
    AZURE_CLIENT_ID:     ${{ secrets.AZURE_CLIENT_ID }}
    AZURE_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
    AZURE_TENANT_ID:     ${{ secrets.AZURE_TENANT_ID }}
  run: ./deploy/push-image.sh
```

If you'd rather invoke the auth and push steps separately (e.g. to push a
one-off ad-hoc tag that doesn't go through `build-image.sh`), the lower-level
flow still works:

```yaml
- name: Authenticate to ACR
  env:
    ACR_NAME:            ${{ secrets.ACR_NAME }}
    AZURE_CLIENT_ID:     ${{ secrets.AZURE_CLIENT_ID }}
    AZURE_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
    AZURE_TENANT_ID:     ${{ secrets.AZURE_TENANT_ID }}
  run: ./deploy/acr-login.sh

- name: Build & push image (ad-hoc tag)
  run: |
    docker build -t "$ACR_NAME.azurecr.io/claurst-ask:${{ github.sha }}" .
    docker push      "$ACR_NAME.azurecr.io/claurst-ask:${{ github.sha }}"
```

### Daemonless builders (kaniko, buildah, oras)

Some build environments (devcontainers without DinD, restricted CI runners,
`gcr.io/kaniko-project/executor`) cannot run a Docker daemon. They speak the
OCI registry HTTP API directly and accept a registry token instead of a
credential-helper entry. Run the login script in `token` mode and capture the
token to a file the builder can read:

```bash
ACR_NAME=claurstacr1a2b3c ACR_LOGIN_MODE=token \
  ./deploy/acr-login.sh > /tmp/acr-token

# kaniko example: --registry-token=$(cat /tmp/acr-token)
# buildah example: buildah login --username 00000000-0000-0000-0000-000000000000 \
#                                 --password "$(cat /tmp/acr-token)" \
#                                 "$ACR_NAME.azurecr.io"
```

```powershell
./deploy/acr-login.ps1 -AcrName claurstacr1a2b3c -Mode Token > token.txt
```

The username paired with this token is always the literal GUID
`00000000-0000-0000-0000-000000000000` (an ACR convention for token-based
auth). Token lifetime is ~3 hours.

## Troubleshooting

| Symptom                                                          | Likely cause                                                | Fix                                                                       |
| ---------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------- |
| `az: command not found` / `az not recognized`                    | Azure CLI not installed                                     | https://aka.ms/InstallAzureCLI                                            |
| `Not logged in to Azure.`                                        | No active `az` session                                      | Run `az login` (interactive) or set `AZURE_CLIENT_*` env vars (CI flow)   |
| `unauthorized: authentication required` on `docker push`         | Token expired (>3h since `az acr login`) or wrong registry  | Re-run `./deploy/acr-login.sh`                                            |
| `denied: requested access to the resource is denied`             | SP lacks `AcrPush` on this registry                         | Re-run `az role assignment create --role AcrPush --assignee <appId> ...`  |
| `Cannot connect to the Docker daemon`                            | Docker not running, or you're on a daemonless build runner  | Start Docker, or use `ACR_LOGIN_MODE=token` / `-Mode Token`               |
| `'<acr>' is not a valid Azure container registry name`           | Passed `<acr>.azurecr.io` instead of `<acr>`                | Strip the `.azurecr.io` suffix — the script appends it where needed       |

## Why we use admin user for the *runtime* but SP for *push*

The Container App pulls images using the registry's **admin user** credentials
(see `acr.bicep` `adminUserEnabled: true` and `secrets/README.md`). That's the
simplest auth path that fits the seed's "no Key Vault, no managed identity
beyond what Container Apps gives us" constraint, and it never leaves the
Container App's secret store.

For *pushing* — which happens from CI, not from the Container App — we
deliberately avoid sharing those admin credentials with the build pipeline.
A scoped `AcrPush` service principal can push but cannot delete tags,
reconfigure the registry, or read the admin password, which keeps a
compromised CI token from blast-radiusing into runtime credentials.
