# verify-app.ps1 — confirm the deployed Container App is running and reachable
# via its public HTTPS FQDN.
#
# PowerShell 7+ counterpart to verify-app.sh. Satisfies **AC 5 Sub-AC 4**:
# "Verify the deployed Container App is running and reachable via its public
# HTTPS FQDN."
#
# Where this fits in the deploy pipeline:
#
#   provision-acr      → registry exists                       (AC 5)
#   provision-env      → Container Apps environment exists     (AC 5 Sub-AC 1)
#   provision-identity → user-assigned managed identity exists (AC 5 / 40102)
#   push-image         → image tag pushed to ACR               (AC 6)
#   provision-app      → Container App created/updated         (AC 5 Sub-AC 2)
#   configure-ingress  → ingress + traffic rules in one        (AC 5 Sub-AC 3)
#   setup-secrets      → DEEPSEEK + CLAURST keys wired         (AC 7)
#   ▶ verify-app ◀     → end-to-end runtime + reachability gate (AC 5 Sub-AC 4)
#
# Why this exists separately from provision-app.ps1:
#
#   provision-app.ps1 ends by printing the FQDN and a curl one-liner — useful,
#   but it doesn't actually probe the endpoint. A green provisioning call
#   means "ARM accepted the resource definition", which is necessary but not
#   sufficient: an image that crash-loops on startup, a container that binds
#   the wrong port, or an ingress that hasn't finished propagating to the
#   front door all produce a healthy ARM resource that fails real traffic.
#   verify-app.ps1 is the explicit "prove the public surface works" gate the
#   Seed's exit_conditions.azure_deployed clause demands.
#
# Read-only by design: this script never mutates state. It is safe to run
# from CI as a release gate, from an operator's laptop as a smoke test, or
# from an external monitoring job. Re-running it is idempotent.
#
# What this script does, in order:
#   1. Confirms `az` is installed, the caller is logged in, and the
#      `containerapp` extension is current.
#   2. Resolves the Container App's resource record. A missing record means
#      provision-app.ps1 hasn't run; we throw with a pointer at that script.
#   3. Asserts properties.provisioningState == "Succeeded".
#   4. Asserts properties.runningStatus == "Running" (when surfaced by az).
#   5. Lists revision replicas and confirms at least one is in
#      `runningState == "Running"`.
#   6. Resolves the public FQDN and asserts ingress is external.
#   7. Performs an actual HTTPS request against `https://<FQDN>/ask` with
#      no X-API-Key header. The Seed-mandated auth contract returns
#      **401 Unauthorized** for any request missing or carrying a wrong
#      X-API-Key (see crates/cli/src/serve_auth.rs and AC 2). A 401 here
#      proves end-to-end:
#        • DNS resolves the per-app subdomain.
#        • Container Apps' managed front door terminates TLS for it.
#        • The container is bound to TARGET_PORT and accepts connections.
#        • The auth middleware is loaded and answering.
#   8. Prints a success summary with the FQDN and ready-to-paste curl
#      commands the operator can use to drive a real /ask request.
#
# Required parameters (positional or named):
#   -ResourceGroup        Resource group containing the Container App
#                         (must match provision-app.ps1).
#   -ContainerApp         Name of the Container App (e.g. claurst-ask).
#
# Optional parameters:
#   -ProbeTimeoutSeconds  Per-request timeout for the HTTPS reachability
#                         probe (default: 30). Should comfortably exceed
#                         normal cold-start latency without exceeding the
#                         platform's 240 s ingress idle timeout.
#   -ProbeRetries         Number of probe retries before failing
#                         (default: 12). Covers the platform front door's
#                         60-90 s post-deploy propagation delay.
#   -ProbeDelaySeconds    Sleep between retries (default: 5). Combined
#                         with -ProbeRetries this gives ~60 s of tolerance
#                         for cold-start.
#
# Example:
#   ./deploy/verify-app.ps1 `
#     -ResourceGroup rg-claurst `
#     -ContainerApp  claurst-ask
#
# Exit status:
#   0  app exists, provisioned, running, ≥1 replica running, ingress
#      external, FQDN responds 401 to an unauthenticated POST /ask.
#   non-zero (throw)  any of: app missing, provisioning failed, no running
#      replica, ingress not external, FQDN unreachable, FQDN responds with
#      something other than 401 to the unauthenticated probe.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,

    # ValidatePattern mirrors Container Apps name rules: 2-32 chars,
    # lowercase alphanumeric + hyphens, must start and end alphanumeric.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$')]
    [string] $ContainerApp,

    # Probe timeout: must allow at least one second; the realistic ceiling
    # is much lower (the probe stops at auth, not the agentic loop), so
    # the default 30 is generous.
    [ValidateRange(1, 240)]
    [int] $ProbeTimeoutSeconds = 30,

    # Retry budget: 12 × 5s = 60s default tolerance for front-door
    # propagation on a brand-new revision. Lower values produce flakier
    # CI; higher values mask real deployment failures.
    [ValidateRange(1, 120)]
    [int] $ProbeRetries = 12,

    # Inter-retry delay: 0 means tight-loop (only sensible for unit
    # tests), so the floor is 1s.
    [ValidateRange(0, 60)]
    [int] $ProbeDelaySeconds = 5
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Preflight: az CLI present, authenticated, containerapp extension installed
# -----------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI"
}

# Cheapest "are we logged in?" probe. Works for both interactive `az login`
# and service-principal sessions; we don't need the output, only the exit
# code. Suppress stderr so a clean failure produces our message, not az's.
$null = az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw @"
Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first.
For CI: AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID via 'az login --service-principal'.
"@
}

$subscriptionName = az account show --query name --output tsv
$subscriptionId   = az account show --query id   --output tsv

Write-Host ">> Active subscription: $subscriptionName ($subscriptionId)"
Write-Host ">> Container App:       $ContainerApp (group: $ResourceGroup)"
Write-Host ">> Probe budget:        $ProbeRetries attempts × ${ProbeDelaySeconds}s delay (per-call timeout: ${ProbeTimeoutSeconds}s)"

# `az containerapp` lives in the `containerapp` extension. Modern Azure CLI
# auto-installs on first use; explicit `extension add` here makes the script
# work on older `az` versions too (matches every other deploy script).
Write-Host ">> Ensuring 'containerapp' Azure CLI extension is installed..."
$installed = az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($installed)) {
    az extension add --name containerapp --only-show-errors --yes --output none | Out-Null
}

# -----------------------------------------------------------------------------
# Step 1: confirm the Container App exists
# -----------------------------------------------------------------------------
#
# We make four small `--query` calls rather than one big `--output json` +
# manual parsing. Each call is ~150 ms; the alternative would force us to
# either depend on `jq` (not part of the contract) or write our own JSON
# parser via `ConvertFrom-Json`. The latter is fine in PowerShell but
# would diverge from verify-app.sh, complicating the cross-shell parity
# review the rest of the deploy/ scripts uphold.

Write-Host ""
Write-Host ">> [1/4] Resolving Container App resource..."

$existingAppId = az containerapp show `
    --name           $ContainerApp `
    --resource-group $ResourceGroup `
    --query id `
    --output tsv 2>$null

if ([string]::IsNullOrEmpty($existingAppId)) {
    throw @"
Container App '$ContainerApp' not found in resource group '$ResourceGroup'.
Run deploy/provision-app.ps1 first to create the app, then re-run this script to verify it.
"@
}

$provisioningState = az containerapp show `
    --name           $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.provisioningState `
    --output tsv

$runningStatus = az containerapp show `
    --name           $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.runningStatus `
    --output tsv 2>$null

$ingressFqdn = az containerapp show `
    --name           $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.fqdn `
    --output tsv 2>$null

$ingressExternal = az containerapp show `
    --name           $ContainerApp `
    --resource-group $ResourceGroup `
    --query properties.configuration.ingress.external `
    --output tsv 2>$null

# `--output tsv` returns the literal string with a trailing newline that
# az appends. Trim each so equality comparisons aren't fooled by whitespace.
$provisioningState = ($provisioningState -as [string]).Trim()
$runningStatus     = ($runningStatus     -as [string]).Trim()
$ingressFqdn       = ($ingressFqdn       -as [string]).Trim()
$ingressExternal   = ($ingressExternal   -as [string]).Trim()

$displayRunning  = if ([string]::IsNullOrEmpty($runningStatus))   { '<unset>' } else { $runningStatus }
$displayExternal = if ([string]::IsNullOrEmpty($ingressExternal)) { '<unset>' } else { $ingressExternal }
$displayFqdn     = if ([string]::IsNullOrEmpty($ingressFqdn))     { '<unset>' } else { $ingressFqdn }

Write-Host "   provisioningState: $provisioningState"
Write-Host "   runningStatus:     $displayRunning"
Write-Host "   ingress.external:  $displayExternal"
Write-Host "   ingress.fqdn:      $displayFqdn"

# -----------------------------------------------------------------------------
# Step 2: assert provisioning + running status
# -----------------------------------------------------------------------------
#
# `provisioningState` is the ARM-level signal that the latest revision
# definition was accepted and the platform finished applying it. Anything
# other than `Succeeded` means provision-app.ps1 / configure-ingress.ps1 /
# configure-runtime.ps1 produced a definition the platform couldn't
# materialise — that's a deploy-time bug, not a runtime hiccup.
#
# `runningStatus` is the data-plane signal — does the platform consider
# the app live? `Running` is the only state that admits traffic; the
# others (`Stopped`, `Suspended`, `Disabled`, `Progressing`) either
# require operator intervention or a retry after the platform finishes
# its own state change.

Write-Host ""
Write-Host ">> [2/4] Asserting Container App state..."

if ($provisioningState -ne 'Succeeded') {
    throw @"
Container App provisioningState is '$provisioningState' (expected 'Succeeded').
Inspect the latest deploy:
  az containerapp show -n $ContainerApp -g $ResourceGroup --query properties
  az containerapp logs show -n $ContainerApp -g $ResourceGroup --type system --follow
"@
}

# `runningStatus` was added relatively late to the API; older `az` versions
# return an empty string rather than the field. Treat empty-string as
# "platform didn't surface the field" (best-effort) and rely on the replica
# probe in Step 3 for the authoritative answer. Anything non-empty other
# than "Running" is a hard failure.
if (-not [string]::IsNullOrEmpty($runningStatus) -and $runningStatus -ne 'Running') {
    throw @"
Container App runningStatus is '$runningStatus' (expected 'Running').
If the app was deliberately stopped, restart with:
  az containerapp revision restart -n $ContainerApp -g $ResourceGroup --revision <name>
"@
}

# -----------------------------------------------------------------------------
# Step 3: confirm at least one replica is actually running
# -----------------------------------------------------------------------------
#
# `runningStatus == "Running"` can briefly precede any replica actually
# being up (image pulling, container starting). The replica list is the
# authoritative answer to "is something serving on this revision?".

Write-Host ""
Write-Host ">> [3/4] Confirming a replica is running..."

$latestRevision = az containerapp revision list `
    --name           $ContainerApp `
    --resource-group $ResourceGroup `
    --query "sort_by([?properties.active], &properties.createdTime) | [-1].name" `
    --output tsv 2>$null

$latestRevision = ($latestRevision -as [string]).Trim()

if ([string]::IsNullOrEmpty($latestRevision)) {
    throw @"
No active revision found for Container App '$ContainerApp'.
Run deploy/provision-app.ps1 to deploy a revision, or check the portal for a failed deployment.
"@
}

Write-Host "   latest active revision: $latestRevision"

# `replica list --revision` is the canonical lookup. `properties.runningState`
# distinguishes between Pending (image pulling), Running (serving), Failed
# (crash-looped), Terminated (decommissioned). Only Running counts.
$runningReplicaCount = az containerapp replica list `
    --name           $ContainerApp `
    --resource-group $ResourceGroup `
    --revision       $latestRevision `
    --query "length([?properties.runningState == 'Running'])" `
    --output tsv 2>$null

# Some `az` versions return the count as `0` and others as empty when no
# replicas match. Normalise both to integer 0.
$runningReplicaCount = ($runningReplicaCount -as [string]).Trim()
if ($runningReplicaCount -notmatch '^[0-9]+$') {
    $runningReplicaCount = '0'
}
$runningReplicaCountInt = [int] $runningReplicaCount

Write-Host "   replicas in 'Running' state: $runningReplicaCountInt"

if ($runningReplicaCountInt -lt 1) {
    throw @"
No replica is in 'Running' state on the latest active revision.
Inspect replica details and container logs:
  az containerapp replica list -n $ContainerApp -g $ResourceGroup --revision $latestRevision -o table
  az containerapp logs show -n $ContainerApp -g $ResourceGroup --revision $latestRevision --follow
"@
}

# -----------------------------------------------------------------------------
# Step 4: probe the public HTTPS FQDN end-to-end
# -----------------------------------------------------------------------------
#
# A green ARM record + a running replica are necessary but not sufficient
# evidence of "reachable via its public HTTPS FQDN". The platform front
# door has its own propagation delay, the binary has to bind a TCP
# listener, and the container has to pass the readiness signal Container
# Apps gates traffic on. The cheapest end-to-end proof is an HTTPS POST
# to /ask with no X-API-Key — the auth middleware (see
# crates/cli/src/serve_auth.rs and AC 2) returns 401 without invoking
# the agentic loop, so the probe completes in milliseconds, requires no
# DEEPSEEK_API_KEY, and proves DNS resolves, TLS terminates, the
# container is bound, and the auth middleware is loaded.

if ([string]::IsNullOrEmpty($ingressFqdn)) {
    throw @"
Container App has no public ingress FQDN — ingress is disabled or hasn't propagated.
Run deploy/configure-ingress.ps1 to enable external HTTPS ingress.
"@
}

# `ingress.external` is reported as the literal string "true" / "false" via
# `--query --output tsv`. Anything else (empty, "True", JSON `true`) means
# the API didn't surface the field; we err on the safe side and require the
# explicit lowercase "true" the canonical response uses.
if ($ingressExternal -ne 'true') {
    throw @"
Container App ingress is not external (ingress.external = '$ingressExternal').
Run deploy/configure-ingress.ps1 to switch ingress visibility to 'external'.
"@
}

$probeUrl = "https://$ingressFqdn/ask"
Write-Host ""
Write-Host ">> [4/4] Probing $probeUrl (expecting 401 from unauthenticated POST)..."

# Probe loop:
#   • Invoke-WebRequest is the canonical PowerShell HTTPS client; -SkipHttpErrorCheck
#     (PowerShell 7+) lets us inspect 4xx responses without it throwing.
#   • -Method POST                match the endpoint's only valid verb.
#   • -ContentType / -Body        match the request shape the auth middleware
#                                 expects (the body is rejected before parsing,
#                                 but matching the real request shape gives the
#                                 most realistic probe).
#   • -TimeoutSec                 per-attempt timeout; defaults to 30 because
#                                 the probe never reaches the agentic loop.
#   • -UseBasicParsing            don't engage the IE DOM (legacy Windows
#                                 PowerShell quirk; harmless on PS7 but keeps
#                                 the script working on the older runtime).

$lastStatus = $null
$lastError  = $null
$succeeded  = $false

for ($attempt = 1; $attempt -le $ProbeRetries; $attempt++) {
    $lastStatus = $null
    $lastError  = $null

    try {
        $response = Invoke-WebRequest `
            -Uri $probeUrl `
            -Method POST `
            -ContentType 'application/json' `
            -Body '{"question":"verify-app probe"}' `
            -TimeoutSec $ProbeTimeoutSeconds `
            -SkipHttpErrorCheck `
            -UseBasicParsing `
            -ErrorAction Stop
        $lastStatus = [int] $response.StatusCode
    } catch {
        # Network-level failure (DNS, TCP refused, TLS handshake, timeout).
        # Re-thrown as a System.Net.* error wrapped in a RuntimeException.
        $lastError = $_.Exception.Message
    }

    if ($lastStatus -eq 401) {
        Write-Host "   attempt ${attempt}/${ProbeRetries}: 401 (expected) — endpoint reachable, auth wiring confirmed."
        $succeeded = $true
        break
    }

    if ($null -ne $lastStatus) {
        Write-Host "   attempt ${attempt}/${ProbeRetries}: HTTP $lastStatus (waiting for 401)"
    } else {
        Write-Host "   attempt ${attempt}/${ProbeRetries}: connection failed ($lastError) — front door not yet reachable"
    }

    if ($attempt -lt $ProbeRetries -and $ProbeDelaySeconds -gt 0) {
        Start-Sleep -Seconds $ProbeDelaySeconds
    }
}

if (-not $succeeded) {
    $diag = New-Object System.Text.StringBuilder
    [void] $diag.AppendLine("Reachability probe FAILED after $ProbeRetries attempt(s).")

    if ($null -ne $lastStatus) {
        [void] $diag.AppendLine("  Last HTTP status:    $lastStatus (expected 401).")
        switch ($lastStatus) {
            403 { [void] $diag.AppendLine("  HTTP 403 typically means the front door rejected the request before reaching the container.") }
            404 { [void] $diag.AppendLine("  HTTP 404 means the route /ask is not wired in this binary build.") }
            502 { [void] $diag.AppendLine("  HTTP 502 means Container Apps reached the container but it did not answer (port mismatch or crash).") }
            503 { [void] $diag.AppendLine("  HTTP 503 means no replica is currently serving (cold-start or all replicas unhealthy).") }
        }
    } else {
        [void] $diag.AppendLine("  Last connection error: $lastError (DNS / TCP / TLS / timeout — see Invoke-WebRequest docs).")
    }

    [void] $diag.AppendLine("")
    [void] $diag.AppendLine("Diagnostic next steps:")
    [void] $diag.AppendLine("  az containerapp logs show -n $ContainerApp -g $ResourceGroup --revision $latestRevision --follow")
    [void] $diag.AppendLine("  az containerapp logs show -n $ContainerApp -g $ResourceGroup --type system --follow")
    [void] $diag.AppendLine("  az containerapp replica list -n $ContainerApp -g $ResourceGroup --revision $latestRevision -o table")

    throw $diag.ToString()
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host ">> Verification PASSED."
Write-Host "   Container App:        $ContainerApp"
Write-Host "   Resource group:       $ResourceGroup"
Write-Host "   Latest revision:      $latestRevision"
Write-Host "   Running replicas:     $runningReplicaCountInt"
Write-Host "   Public FQDN:          https://$ingressFqdn"
Write-Host "   /ask probe (no key):  401 Unauthorized (expected) ✅"
Write-Host ""
Write-Host "   Drive a real /ask request — supply your CLAURST_API_KEY and try one:"
Write-Host ""
Write-Host "   curl -sSf -X POST https://$ingressFqdn/ask ``"
Write-Host "     -H `"X-API-Key: `$env:CLAURST_API_KEY`" ``"
Write-Host "     -H 'Content-Type: application/json' ``"
Write-Host "     -d '{`"question`":`"What is the capital of France?`"}'"
Write-Host ""
Write-Host "   Tail logs while you exercise it:"
Write-Host ""
Write-Host "   az containerapp logs show ``"
Write-Host "     --name $ContainerApp ``"
Write-Host "     --resource-group $ResourceGroup ``"
Write-Host "     --revision $latestRevision ``"
Write-Host "     --follow"
