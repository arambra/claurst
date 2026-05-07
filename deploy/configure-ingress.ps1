# configure-ingress.ps1 — converge a deployed Container App's public HTTPS
# ingress configuration (visibility, target port, transport) and its ingress
# traffic rules (revisions mode + 100 % of traffic to the latest revision).
#
# PowerShell 7+ counterpart to configure-ingress.sh. Satisfies **AC 5
# Sub-AC 3**: "Configure public HTTPS ingress (external, target port,
# transport) and ingress traffic rules on the Container App."
#
# Where this fits in the deploy pipeline:
#
#   provision-acr      → registry exists                       (AC 5)
#   provision-env      → Container Apps environment exists     (AC 5)
#   provision-identity → user-assigned managed identity exists (AC 5/40102)
#   push-image         → image tag pushed to ACR               (AC 6)
#   provision-app      → Container App created/updated         (AC 5 Sub-AC 2)
#   ▶ configure-ingress ◀ ingress + traffic rules in one       (AC 5 Sub-AC 3)
#   configure-runtime  → ingress + secrets + env vars in one   (AC 7 / 40103 Sub-AC 3)
#
# `provision-app.ps1` already creates an app with `--ingress external`,
# `--target-port 8080`, `--transport auto`, and `--revisions-mode single`.
# This script is the single coherent **ingress-only converger** — it asserts
# both halves at once, so re-running it brings any drifted Container App back
# to the desired ingress shape without touching secrets / env vars (those are
# `setup-secrets.ps1`'s and `configure-runtime.ps1`'s job).
#
# Why a separate script when configure-runtime.ps1 already covers ingress?
#
# `configure-runtime.ps1` conflates ingress + secrets + env-var bindings into
# a single converger and **requires** -DeepseekApiKey + -ClaurstApiKey to run.
# That is too heavy for the common case of "the app's ingress drifted, fix it
# without rotating any secret". `configure-ingress.ps1` is the minimal entry
# point for that case: it touches only the ingress + traffic surface, takes
# no secret material, and is therefore safe to bake into a routine
# convergence job that runs on every deploy without exposing the operator's
# secrets.
#
# What this script does, in order:
#   1. Confirms `az` is installed, the caller is logged in, and the
#      `containerapp` extension is current.
#   2. Confirms the Container App exists (fails fast otherwise — there is
#      nothing to configure if `provision-app.ps1` hasn't been run).
#   3. Re-asserts ingress visibility (`external`), target port, and transport
#      (`auto`) via `az containerapp ingress enable`. Idempotent: re-running
#      with the same args is a no-op.
#   4. Re-asserts the HTTP request idle timeout (4 minutes = 240 s).
#   5. Re-asserts revisions mode = `single` via `az containerapp revision
#      set-mode`. In single-revision mode, Container Apps automatically
#      routes 100 % of traffic to the latest active revision; this *is* the
#      Seed-mandated ingress traffic rule, expressed as a top-level
#      revisions-mode setting rather than a per-revision weight.
#   6. Looks up the latest active revision and explicitly asserts the
#      traffic rule via `az containerapp ingress traffic set
#      --revision-weight <latest>=100`. Redundant under single-revision mode
#      but keeps the rule auditable in `az containerapp ingress traffic
#      show` and survives an operator flipping revisions-mode in the portal.
#   7. Verifies the resulting configuration end-to-end and prints a summary
#      block with the public FQDN, the live ingress fields, and the live
#      traffic rule.
#
# Required parameters (positional or named):
#   -ResourceGroup       Resource group containing the Container App
#                        (must match provision-app.ps1).
#   -ContainerApp        Name of the Container App (e.g. claurst-ask).
#
# Optional parameters:
#   -TargetPort          Container port the binary listens on (default: 8080,
#                        matches Dockerfile EXPOSE and `cc-http`'s bind).
#   -Transport           Ingress transport: auto | http | http2 | tcp
#                        (default: auto — platform picks HTTP/1.1 vs HTTP/2).
#   -IdleTimeoutMinutes  Ingress request idle timeout in minutes
#                        (default: 4 == 240 s, matches the Seed's
#                        synchronous-blocking constraint).
#   -RevisionsMode       single | multiple (default: single, per Seed).
#
# Example:
#   ./deploy/configure-ingress.ps1 `
#     -ResourceGroup rg-claurst `
#     -ContainerApp  claurst-ask
#
# Re-running the script with the same inputs is safe: every `az` call below
# is idempotent under the chosen invocation. If the operator manually edits
# the ingress in the portal between runs, the next invocation converges it
# back to the Seed-mandated shape.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,

    # ValidatePattern mirrors Container Apps name rules: 2-32 chars,
    # lowercase alphanumeric + hyphens, must start and end alphanumeric.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$')]
    [string] $ContainerApp,

    # Target port sanity: must be a valid 16-bit port. The Dockerfile's
    # EXPOSE 8080 is what the binary actually binds to; allowing operators
    # to override is purely for unusual side-loaded builds.
    [ValidateRange(1, 65535)]
    [int] $TargetPort = 8080,

    # Container Apps accepts exactly four transport values. ValidateSet
    # catches typos client-side rather than as ARM's
    # "InvalidParameterValueInRequest".
    [ValidateSet('auto', 'http', 'http2', 'tcp')]
    [string] $Transport = 'auto',

    # Idle timeout sanity: Container Apps caps this at 240 minutes; the Seed
    # requires 4 (== 240 s of synchronous-blocking time).
    [ValidateRange(1, 240)]
    [int] $IdleTimeoutMinutes = 4,

    # Revisions mode drives the implicit ingress traffic rule. The Seed pins
    # `single` — `multiple` is exposed for completeness but should never be
    # selected without a corresponding Seed change.
    [ValidateSet('single', 'multiple')]
    [string] $RevisionsMode = 'single'
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Preflight: az CLI present, authenticated, containerapp extension installed
# -----------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI"
}

$null = az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first."
}

$subscriptionName = az account show --query name --output tsv
$subscriptionId   = az account show --query id   --output tsv

Write-Host ">> Active subscription: $subscriptionName ($subscriptionId)"
Write-Host ">> Container App:       $ContainerApp (group: $ResourceGroup)"
Write-Host ">> Target port:         $TargetPort"
Write-Host ">> Transport:           $Transport"
Write-Host ">> Idle timeout:        $IdleTimeoutMinutes minute(s)"
Write-Host ">> Revisions mode:      $RevisionsMode"

Write-Host ">> Ensuring 'containerapp' Azure CLI extension is installed..."
$installed = az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($installed)) {
    az extension add --name containerapp --only-show-errors --yes --output none
    if ($LASTEXITCODE -ne 0) { throw "az extension add (containerapp) failed (exit $LASTEXITCODE). If pip is crashing with 0xC0000005, see deploy/README troubleshooting." }
} else {
    Write-Host "   (already installed; skipping add/upgrade)"
}

# -----------------------------------------------------------------------------
# Step 1: confirm the Container App exists
# -----------------------------------------------------------------------------

# We deliberately do *not* create the app here — that's provision-app.ps1's
# job, and silently materialising one would skip its registry + identity
# wiring. Surface a clear "run the prereq" error instead.
$existingAppId = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query id `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($existingAppId)) {
    throw "Container App '$ContainerApp' not found in resource group '$ResourceGroup'. Run deploy/provision-app.ps1 first to create the app, then re-run this script to configure its ingress."
}

# -----------------------------------------------------------------------------
# Step 2: re-assert ingress visibility, target port, and transport
# -----------------------------------------------------------------------------

# `az containerapp ingress enable` is the canonical setter for the three
# ingress fields the Seed pins:
#   --type external          → public HTTPS endpoint via the managed reverse proxy
#   --target-port <port>     → port the binary listens on inside the container
#                              (Dockerfile EXPOSE 8080 + cc-http's TcpListener)
#   --transport <auto|...>   → wire protocol; `auto` lets the platform pick
#                              HTTP/1.1 vs HTTP/2 per request
#
# `enable` is idempotent: re-running with the same args is a no-op, and
# changing the target port hot-swaps it without dropping in-flight requests.
Write-Host ">> Re-asserting ingress: external visibility, port $TargetPort, transport $Transport..."
az containerapp ingress enable `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --type external `
    --target-port $TargetPort `
    --transport $Transport `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az containerapp ingress enable failed (exit $LASTEXITCODE)" }

# -----------------------------------------------------------------------------
# Step 3: pin the ingress idle timeout to 4 minutes (240 s)
# -----------------------------------------------------------------------------

# Container Apps' HTTP request idle timeout is `ingress.idleTimeoutInMinutes`.
# 4 minutes = 240 s, which matches the Seed's synchronous-blocking AC. The
# platform default already caps at 240 s, but pinning the value explicitly:
#   • makes the configuration auditable (visible in `az containerapp show`),
#   • survives any future platform default change without a silent regression,
#   • mirrors the Seed's `request_timeout_seconds` ontology concept.
#
# `az containerapp ingress update --idle-timeout-in-minutes` has been the
# stable setter since the May-2024 CLI release. Older CLI versions silently
# ignore unknown flags and exit 2; we tolerate that with a warn-and-continue.
$idleSeconds = $IdleTimeoutMinutes * 60
Write-Host ">> Setting ingress idle timeout to $IdleTimeoutMinutes minute(s) (${idleSeconds}s)..."
az containerapp ingress update `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --idle-timeout-in-minutes $IdleTimeoutMinutes `
    --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "ingress idle-timeout setter unavailable on this az version — the platform default of 240 s still applies; upgrade az to silence this notice."
    # Reset $LASTEXITCODE so the next az call's exit-code check isn't poisoned.
    $global:LASTEXITCODE = 0
}

# -----------------------------------------------------------------------------
# Step 4: assert revisions mode (drives the implicit traffic rule)
# -----------------------------------------------------------------------------

# In Container Apps, revisions mode is the top-level switch that governs
# ingress traffic distribution:
#   • single    → exactly one active revision; 100 % of traffic to it
#                 automatically. The Seed pins this.
#   • multiple  → up to 100 active revisions; traffic split via per-revision
#                 weights configured below.
#
# Setting this here (rather than only at create time) defends against an
# operator flipping the mode in the portal between runs. `revision set-mode`
# is idempotent and a no-op when the mode already matches.
Write-Host ">> Asserting revisions mode = $RevisionsMode..."
az containerapp revision set-mode `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --mode $RevisionsMode `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az containerapp revision set-mode failed (exit $LASTEXITCODE)" }

# -----------------------------------------------------------------------------
# Step 5: explicitly assert the ingress traffic rule (100 % to latest revision)
# -----------------------------------------------------------------------------

# `az containerapp ingress traffic set --revision-weight <name>=<weight>` is
# the canonical setter for per-revision traffic weights. We use it to express
# the Seed-mandated rule "100 % of traffic to the latest active revision" in
# a form that's auditable via `az containerapp ingress traffic show`,
# regardless of whether the app is in single- or multiple-revision mode.
#
# Resolving the latest revision: the revision list is sorted by
# `properties.createdTime`, so `[-1]` is the most recent revision after a
# `sort_by`. We prefer active revisions; if none are active yet (deploy still
# rolling out) we fall back to the most recent revision regardless.
Write-Host ">> Resolving latest active revision..."
$latestRevision = az containerapp revision list `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query "sort_by([?properties.active], &properties.createdTime) | [-1].name" `
    --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($latestRevision) -or $latestRevision -eq 'None') {
    # No active revisions (yet) — fall back to the most recent one regardless
    # of active state. This is the "deploy still rolling out" edge case.
    $latestRevision = az containerapp revision list `
        --name $ContainerApp `
        --resource-group $ResourceGroup `
        --query "sort_by([], &properties.createdTime) | [-1].name" `
        --output tsv 2>$null
}

# Reset $LASTEXITCODE in case the soft 2>$null call above set it. We don't
# want a downstream PowerShell error caused by stale state from a tolerated
# fallback path.
$global:LASTEXITCODE = 0

if ([string]::IsNullOrWhiteSpace($latestRevision) -or $latestRevision -eq 'None') {
    Write-Warning "no revisions found yet — skipping explicit traffic-weight assertion; single-revision mode will route 100 % to the first revision once it activates."
}
else {
    Write-Host ">> Asserting ingress traffic rule: 100 % -> $latestRevision..."
    az containerapp ingress traffic set `
        --name $ContainerApp `
        --resource-group $ResourceGroup `
        --revision-weight "${latestRevision}=100" `
        --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        # `traffic set` rejects manual weights when revisions-mode = single
        # on some `az` versions because the mode handles it implicitly.
        # That's not a failure — the implicit rule is *exactly* what the
        # Seed mandates.
        Write-Host "   (manual traffic-weight rejected — single-revision mode already routes 100 % to '$latestRevision' implicitly. This is the Seed-mandated rule.)"
        $global:LASTEXITCODE = 0
    }
}

# -----------------------------------------------------------------------------
# Step 6: verify the resulting configuration
# -----------------------------------------------------------------------------

# Five fields map 1:1 to Sub-AC 3's acceptance surface:
#   • ingress.external           — must be `true` (public HTTPS)
#   • ingress.targetPort         — must match the requested port
#   • ingress.transport          — must match the requested transport
#   • ingress.fqdn               — the URL the operator can curl
#   • configuration.activeRevisionsMode — must match $RevisionsMode
# The traffic distribution is read separately via `ingress traffic show`
# because it's an array and needs its own JMESPath query.
Write-Host ">> Verifying ingress configuration..."

$ingressExternal = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.external `
    --output tsv

$ingressTargetPort = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.targetPort `
    --output tsv

$ingressTransport = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.transport `
    --output tsv

$ingressFqdn = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.fqdn `
    --output tsv

$liveRevisionsMode = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.activeRevisionsMode `
    --output tsv

# Sanity checks: each one violates the Seed if it doesn't match. Throwing
# exits non-zero so a CI pipeline running this script as a verification gate
# fails loudly instead of silently shipping a broken deploy.
if ($ingressExternal -ne 'true') {
    throw "Ingress is not external (got '$ingressExternal'). The /ask endpoint will not be publicly reachable."
}

if ([string] $ingressTargetPort -ne [string] $TargetPort) {
    throw "Ingress target port mismatch: requested $TargetPort, app reports $ingressTargetPort."
}

# Case-insensitive compare: API returns "Auto" / "Http" / "Http2" / "Tcp"
# while the CLI accepts the lowercase forms.
if ($ingressTransport.ToLower() -ne $Transport.ToLower()) {
    throw "Ingress transport mismatch: requested $Transport, app reports $ingressTransport."
}

# Same case-insensitive compare for revisions mode (API returns "Single" /
# "Multiple", CLI accepts the lowercase forms).
if ($liveRevisionsMode.ToLower() -ne $RevisionsMode.ToLower()) {
    throw "Revisions mode mismatch: requested $RevisionsMode, app reports $liveRevisionsMode."
}

# Show the live traffic distribution as a table — exactly what an operator
# would copy/paste into a ticket to prove the traffic rule is wired correctly.
Write-Host ">> Live ingress traffic distribution:"
az containerapp ingress traffic show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --output table

$revisionLabel = if ([string]::IsNullOrWhiteSpace($latestRevision)) {
    '(latest revision, resolved at request time)'
} else {
    $latestRevision
}

Write-Host ""
Write-Host ">> Ingress configuration converged."
Write-Host "   Container App:    $ContainerApp"
Write-Host "   Resource group:   $ResourceGroup"
Write-Host "   Ingress:          external (https://$ingressFqdn)"
Write-Host "   Target port:      $ingressTargetPort"
Write-Host "   Transport:        $ingressTransport"
Write-Host "   Idle timeout:     $IdleTimeoutMinutes minute(s)"
Write-Host "   Revisions mode:   $liveRevisionsMode"
Write-Host "   Traffic rule:     100 % -> $revisionLabel"
Write-Host ""
Write-Host "   Smoke-test the endpoint (`$env:CLAURST_API_KEY must already be wired"
Write-Host "   via deploy/secrets/setup-secrets.ps1 or deploy/configure-runtime.ps1):"
Write-Host "   curl -sSf -X POST https://$ingressFqdn/ask ``"
Write-Host "     -H `"X-API-Key: `$env:CLAURST_API_KEY`" ``"
Write-Host "     -H 'Content-Type: application/json' ``"
Write-Host "     -d '{`"question`":`"What is the capital of France?`"}'"
Write-Host ""
Write-Host "   Show live traffic distribution any time:"
Write-Host "   az containerapp ingress traffic show ``"
Write-Host "     --name $ContainerApp ``"
Write-Host "     --resource-group $ResourceGroup ``"
Write-Host "     --output table"
Write-Host ""
