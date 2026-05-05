# Container Apps Secrets

This directory provisions and rotates the two secrets that the `claurst-ask`
REST endpoint needs at runtime, satisfying AC 7 of the deployment seed:
**DEEPSEEK_API_KEY and X-API-Key are configured as Container Apps secrets and
injected as env vars.**

Per the seed constraints there is no Bicep, no Terraform, no Key Vault — just
direct `az containerapp` CLI calls.

## Secret → environment variable mapping

| Container Apps secret | Container env var  | Purpose                                                          |
| --------------------- | ------------------ | ---------------------------------------------------------------- |
| `deepseek-api-key`    | `DEEPSEEK_API_KEY` | Outbound auth to DeepSeek's Anthropic-compatible chat API        |
| `claurst-api-key`     | `CLAURST_API_KEY`  | Compared by the server against the inbound `X-API-Key` HTTP header |

The Rust binary reads `CLAURST_API_KEY` once at startup and rejects any request
whose `X-API-Key` header does not match in constant time. `DEEPSEEK_API_KEY` is
forwarded into `cc-api`'s `Config` exactly as it is in local development, so no
code path changes between `cargo run` and Container Apps.

## Why `secretref:` instead of literal env values

`az containerapp update --set-env-vars NAME=secretref:secret-name` stores only
the reference in the revision template. The literal value lives in the
Container App's encrypted secret store and is resolved by the platform at
container start — it never appears in `az containerapp show` output, ARM export,
or activity logs. Rotating a key is then a single `az containerapp secret set`
followed by a revision restart; no code or template change.

## Usage

### PowerShell 7+ (Windows / Linux / macOS via `pwsh`)

```powershell
./setup-secrets.ps1 `
  -ResourceGroup  rg-claurst `
  -ContainerApp   claurst-ask `
  -DeepseekApiKey 'sk-...' `
  -ClaurstApiKey  ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N'))
```

Both scripts are idempotent: re-running them updates the existing secrets and
the env-var bindings in place. A new revision is rolled out with `min replicas
1, max replicas 1` (the existing scale config is preserved — these scripts do
not touch replica count or ingress).

## Rotating a key

```powershell
# Rotate the inbound shared secret without downtime:
$new = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })

az containerapp secret set `
  --name claurst-ask --resource-group rg-claurst `
  --secrets "claurst-api-key=$new"
az containerapp revision restart `
  --name claurst-ask --resource-group rg-claurst `
  --revision (az containerapp revision list -n claurst-ask -g rg-claurst --query '[0].name' -o tsv)
```

The DeepSeek key rotates the same way — replace `claurst-api-key` with
`deepseek-api-key`.

## Verifying the binding (without leaking values)

```powershell
az containerapp show -n claurst-ask -g rg-claurst `
  --query "properties.template.containers[0].env[?name=='DEEPSEEK_API_KEY' || name=='CLAURST_API_KEY']" `
  -o table
```

Expected output shows both env vars with `secretRef` populated and `value`
empty — confirming the runtime resolves them from the secret store rather than
carrying literals in the template.
