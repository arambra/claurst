# Container App Runtime Configuration

Single coherent operation that converges a deployed `claurst-ask` Container App
to the runtime shape the `/ask` REST endpoint requires:

* **Ingress**: `external` visibility, target port matching the binary's listener
  (default 8080), HTTP request idle timeout of 4 minutes (240 seconds — the
  Seed's synchronous-blocking deadline).
* **Secrets**: `deepseek-api-key` and `claurst-api-key` stored in the Container
  App's encrypted secret store.
* **Env vars**: `DEEPSEEK_API_KEY` and `CLAURST_API_KEY` bound to those secrets
  via `secretref:` indirection — the literal values never appear in the
  revision template, ARM exports, or activity logs.

This satisfies **AC 40103 Sub-AC 3** ("Configure Container App ingress
(external, target port) and environment variables/secrets required for the
/ask endpoint runtime"). Per the Seed: no Bicep, no Terraform, no Key Vault —
direct `az containerapp` CLI only.

## Where this fits

```
provision-acr      → registry exists                       (AC 5)
provision-env      → Container Apps environment exists     (AC 5)
provision-identity → user-assigned managed identity exists (AC 5/40102)
push-image         → image tag pushed to ACR               (AC 6)
provision-app      → Container App created/updated         (AC 40102 Sub-AC 2)
configure-runtime  ← ingress + secrets + env vars in one   (AC 40103 Sub-AC 3)
```

`provision-app` already creates an app with the correct ingress and identity
attachment. `secrets/setup-secrets` already stores both secrets and binds them
to env vars. `configure-runtime` is the **single coherent converger** — it
asserts both halves at once, so re-running it brings any drifted Container App
back to the desired state without forcing the operator to remember which
subset of the previous scripts to re-run.

## Configuration matrix

| Setting               | Value (default)                         | Why                                             |
| --------------------- | --------------------------------------- | ----------------------------------------------- |
| `ingress.external`    | `true`                                  | Seed: public HTTPS ingress                      |
| `ingress.targetPort`  | `8080`                                  | Dockerfile EXPOSE 8080, `serve.rs` binds same   |
| `ingress.transport`   | `auto`                                  | Platform picks HTTP/1.1 vs HTTP/2 per request   |
| `ingress.idleTimeout` | `4` minutes (240 s)                     | Seed: synchronous-blocking, 240 s request budget|
| Secret `deepseek-api-key` | from `-DeepseekApiKey` / `DEEPSEEK_API_KEY` | Outbound auth to DeepSeek's Anthropic-compatible API |
| Secret `claurst-api-key`  | from `-ClaurstApiKey` / `CLAURST_API_KEY`   | Inbound `X-API-Key` shared secret                |
| Env var `DEEPSEEK_API_KEY` | `secretref:deepseek-api-key`       | `cc-api` Config picks it up exactly as in local dev |
| Env var `CLAURST_API_KEY`  | `secretref:claurst-api-key`        | `serve_auth.rs` reads at startup; refuses to start auth-less |

The two env-var names above are part of the Rust binary's read-only contract.
Do **not** introduce alternate spellings (`ANTHROPIC_API_KEY`, `API_KEY`, …)
on the server path — they would let a misconfigured deployment silently start
without auth. The contract is pinned at the source by:

* `crates/cli/src/serve_auth.rs` — `API_KEY_ENV_VAR = "CLAURST_API_KEY"`
* `crates/cli/src/serve_auth.rs::api_key_env_var_is_claurst_api_key` test
* `deploy/secrets/README.md` (AC 7's contract)

## Usage

### Bash (CI / Linux / macOS / WSL)

```bash
export AZ_RESOURCE_GROUP=rg-claurst
export AZ_CONTAINERAPP=claurst-ask
export DEEPSEEK_API_KEY="sk-..."                    # from DeepSeek console
export CLAURST_API_KEY="$(openssl rand -hex 32)"    # generate once, share with callers

./deploy/configure-runtime.sh
```

Optional overrides:

```bash
TARGET_PORT=8080 \
IDLE_TIMEOUT_MINUTES=4 \
./deploy/configure-runtime.sh
```

### PowerShell (Windows)

```powershell
$inbound = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })

./deploy/configure-runtime.ps1 `
  -ResourceGroup  rg-claurst `
  -ContainerApp   claurst-ask `
  -DeepseekApiKey 'sk-...' `
  -ClaurstApiKey  $inbound
```

Both scripts are idempotent: re-running them updates the existing
configuration in place. The script:

1. Confirms `az` is installed, you're logged in, and the `containerapp`
   extension is current.
2. Confirms the Container App exists (fails fast otherwise — there is
   nothing to configure if `provision-app` hasn't been run).
3. Re-asserts ingress: external visibility, target port, idle timeout.
4. Stores both Container Apps secrets.
5. Binds the secrets to env vars on the running container.
6. Verifies the resulting configuration end-to-end and prints a summary
   block with the public FQDN and a copy-pasteable smoke-test `curl`.

## Verifying without leaking values

```bash
az containerapp show -n claurst-ask -g rg-claurst \
  --query "{ingress: properties.configuration.ingress, secrets: properties.configuration.secrets[].name, env: properties.template.containers[0].env[?name=='DEEPSEEK_API_KEY' || name=='CLAURST_API_KEY']}" \
  -o json
```

Expected fields (literal values are never returned):

```json
{
  "ingress": {
    "external": true,
    "targetPort": 8080,
    "transport": "Auto",
    "idleTimeoutInMinutes": 4,
    "fqdn": "claurst-ask.<region>.azurecontainerapps.io"
  },
  "secrets": ["claurst-api-key", "deepseek-api-key"],
  "env": [
    { "name": "DEEPSEEK_API_KEY", "secretRef": "deepseek-api-key", "value": null },
    { "name": "CLAURST_API_KEY",  "secretRef": "claurst-api-key",  "value": null }
  ]
}
```

If `value` is non-null on either env entry, a previous run wired the literal
into the template instead of the secret reference — re-run
`configure-runtime` to converge.

## Rotating a key

```bash
NEW=$(openssl rand -hex 32)
DEEPSEEK_API_KEY="$EXISTING_DEEPSEEK_KEY" \
CLAURST_API_KEY="$NEW" \
./deploy/configure-runtime.sh

# Re-running configure-runtime triggers a new revision; if you'd rather not
# re-roll the revision, set just the secret value and restart the active one:
az containerapp secret set \
  --name claurst-ask --resource-group rg-claurst \
  --secrets "claurst-api-key=$NEW"
az containerapp revision restart \
  --name claurst-ask --resource-group rg-claurst \
  --revision "$(az containerapp revision list -n claurst-ask -g rg-claurst --query '[0].name' -o tsv)"
```

## Relationship to the other scripts

| Script                            | Scope                                      |
| --------------------------------- | ------------------------------------------ |
| `deploy/provision-app.sh`         | **Create** the Container App with ingress + identity. Run once per environment. |
| `deploy/configure-ingress.sh`     | **Converge** ingress + traffic rules only (no secrets). Safe to run on every deploy. (AC 5 Sub-AC 3) |
| `deploy/secrets/setup-secrets.sh` | Store secrets + bind env vars only (no ingress). Smaller cousin of `configure-runtime`. |
| `deploy/configure-runtime.sh`     | **Converge** ingress + secrets + env vars on an existing app. Run after every config change or rotation. (AC 7 / 40103 Sub-AC 3) |

`configure-runtime` is a strict superset of `setup-secrets` (it does
everything `setup-secrets` does plus the ingress assertions). `setup-secrets`
remains useful as the focused "rotate just the secret values" entry point;
`configure-runtime` is the entry point for "make sure the runtime is wired
correctly end-to-end".

`configure-ingress` is the **focused ingress + traffic-rules converger** for
AC 5 Sub-AC 3. It overlaps with the ingress assertions in `configure-runtime`
but takes no secret material, so it's safe to wire into a routine
"reconcile-on-every-deploy" job without exposing the operator's keys. It
also adds the explicit `--revision-weight latest=100` traffic-rule
assertion that `configure-runtime` does not — see the comments in
`deploy/configure-ingress.sh` for the rationale.
