# smoke-test-ask.ps1 — drive the canonical AC 8 curl-equivalent against a
# deployed Container App and assert it returns a valid JSON answer.
#
# Satisfies **AC 8**: "curl -H 'X-API-Key: ...' -d '{"question":"..."}'
# https://<app>.azurecontainerapps.io/ask returns a valid JSON answer".
#
# This is the PowerShell counterpart to deploy/smoke-test-ask.sh. It uses
# Invoke-WebRequest rather than curl so it works on stock Windows /
# PowerShell 5+ without an external curl install. Behaviour is identical to
# the bash variant: 200 with `{ "answer": "<non-empty string>" }` passes,
# anything else fails with actionable diagnostics.
#
# Usage:
#
#   $env:CLAURST_API_KEY = '...'
#
#   # Direct: pass the FQDN explicitly
#   ./deploy/smoke-test-ask.ps1 `
#     -AppFqdn 'claurst-ask.salmonbay-12345.azurecontainerapps.io'
#
#   # Indirect: resolve the FQDN via az
#   ./deploy/smoke-test-ask.ps1 `
#     -ResourceGroup 'rg-claurst' `
#     -ContainerApp 'claurst-ask'
#
# Exit code: 0 on success, 1 on any failure.

[CmdletBinding(DefaultParameterSetName = 'ByFqdn')]
param(
  # Public FQDN of the Container App (e.g. claurst-ask.<env>.azurecontainerapps.io).
  [Parameter(ParameterSetName = 'ByFqdn', Mandatory = $true)]
  [string] $AppFqdn,

  # Container App name and resource group — used to resolve the FQDN via az.
  [Parameter(ParameterSetName = 'ByName', Mandatory = $true)]
  [string] $ResourceGroup,
  [Parameter(ParameterSetName = 'ByName', Mandatory = $true)]
  [string] $ContainerApp,

  # Inbound shared secret (the same value passed to setup-secrets.ps1).
  # Falls back to the CLAURST_API_KEY env var so secrets stay out of shell history.
  [string] $ApiKey = $env:CLAURST_API_KEY,

  # Question body sent to /ask. Default chosen to elicit a deterministic,
  # short answer from any general-purpose LLM.
  [string] $Question = 'What is the capital of France? Reply in one short sentence.',

  # Per-request timeout (seconds). Matches the platform ingress idle timeout.
  [int] $TimeoutSeconds = 240,

  # Retry budget for transient cold-start / upstream rate-limit blips.
  [int] $Retries = 3,

  # Delay between retries (seconds).
  [int] $DelaySeconds = 5
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  Write-Error 'CLAURST_API_KEY is not set and no -ApiKey was passed. Pass the same value used in setup-secrets.ps1.'
  exit 1
}

if ($TimeoutSeconds -lt 1) {
  Write-Error "TimeoutSeconds must be a positive integer, got $TimeoutSeconds."
  exit 1
}
if ($Retries -lt 1) {
  Write-Error "Retries must be a positive integer, got $Retries."
  exit 1
}
if ($DelaySeconds -lt 0) {
  Write-Error "DelaySeconds must be a non-negative integer, got $DelaySeconds."
  exit 1
}

# -----------------------------------------------------------------------------
# Resolve the public FQDN
# -----------------------------------------------------------------------------
#
# Two acceptable inputs (mirrored 1:1 with the bash variant):
#   * -AppFqdn passed directly.
#   * -ResourceGroup + -ContainerApp — script asks `az containerapp show`
#     for the ingress FQDN.

if ($PSCmdlet.ParameterSetName -eq 'ByName') {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error 'az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI or use the -AppFqdn parameter set.'
    exit 1
  }

  $accountCheck = & az account show --output none 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged in to Azure. Run 'az login' first."
    exit 1
  }

  $AppFqdn = & az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query 'properties.configuration.ingress.fqdn' `
    --output tsv 2>$null

  if ([string]::IsNullOrWhiteSpace($AppFqdn)) {
    Write-Error "Could not resolve FQDN for Container App '$ContainerApp' in '$ResourceGroup'. Confirm the app exists and ingress is enabled."
    exit 1
  }
}

# Reject anything that doesn't look like a Container Apps FQDN — the script
# stitches `https://${AppFqdn}/ask` so a raw URL or path-bearing value
# would silently produce a malformed request.
if ($AppFqdn -notmatch '^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$') {
  Write-Error "AppFqdn='$AppFqdn' does not look like a bare hostname — strip the scheme/path and pass just the FQDN."
  exit 1
}

$ProbeUrl = "https://$AppFqdn/ask"
$RequestBody = @{ question = $Question } | ConvertTo-Json -Compress
$KeyTail = if ($ApiKey.Length -ge 4) { $ApiKey.Substring($ApiKey.Length - 4) } else { '****' }

Write-Host ">> Smoke-testing /ask against $ProbeUrl"
Write-Host "   question:     $Question"
Write-Host "   timeout:      ${TimeoutSeconds}s per attempt"
Write-Host "   retry budget: $Retries attempt(s) with ${DelaySeconds}s delay"
Write-Host "   x-api-key:    *****$KeyTail    # last 4 chars only"

# -----------------------------------------------------------------------------
# Probe loop
# -----------------------------------------------------------------------------

$attempt = 0
$lastResponse = $null
$lastStatus = $null
$lastError = $null

while ($attempt -lt $Retries) {
  $attempt++
  $lastError = $null
  $lastResponse = $null
  $lastStatus = $null

  try {
    # Invoke-WebRequest treats 4xx/5xx as terminating errors, so we wrap in
    # try/catch and inspect $_.Exception.Response on the failure path. This
    # mirrors curl's "give me the body and the status code" pattern.
    $lastResponse = Invoke-WebRequest -Uri $ProbeUrl `
      -Method Post `
      -Headers @{
        'X-API-Key'    = $ApiKey
        'Content-Type' = 'application/json'
      } `
      -Body $RequestBody `
      -TimeoutSec $TimeoutSeconds `
      -UseBasicParsing
    $lastStatus = [int]$lastResponse.StatusCode
  }
  catch {
    $lastError = $_
    if ($_.Exception.Response) {
      $lastStatus = [int]$_.Exception.Response.StatusCode
      try {
        $reader = New-Object System.IO.StreamReader(
          $_.Exception.Response.GetResponseStream())
        $errorBody = $reader.ReadToEnd()
        $reader.Close()
        $lastResponse = [pscustomobject]@{
          StatusCode = $lastStatus
          Content    = $errorBody
        }
      }
      catch {
        # Swallow — we'll fall through to the diagnostics block below.
      }
    }
  }

  if ($lastStatus -eq 200) {
    Write-Host "   attempt $attempt/$($Retries): 200 OK — validating response body..."
    break
  }

  if ($null -ne $lastStatus) {
    Write-Host "   attempt $attempt/$($Retries): HTTP $lastStatus (expected 200)"
  }
  else {
    Write-Host "   attempt $attempt/$($Retries): connection-level failure ($($lastError.Exception.Message))"
  }

  if ($attempt -lt $Retries) {
    Start-Sleep -Seconds $DelaySeconds
  }
}

# -----------------------------------------------------------------------------
# Failure diagnostics
# -----------------------------------------------------------------------------

if ($lastStatus -ne 200) {
  Write-Host ''
  Write-Error "Smoke test FAILED after $Retries attempt(s)."

  switch ($lastStatus) {
    401 { Write-Host '  HTTP 401 = X-API-Key rejected. Confirm CLAURST_API_KEY matches setup-secrets.ps1.' -ForegroundColor Yellow }
    404 { Write-Host "  HTTP 404 = /ask route is not wired. Check the running image actually starts 'claude serve'." -ForegroundColor Yellow }
    413 { Write-Host '  HTTP 413 = context window exceeded. Shorten the question.' -ForegroundColor Yellow }
    502 { Write-Host '  HTTP 502 = upstream model call failed. Confirm DEEPSEEK_API_KEY is correct and DeepSeek is reachable.' -ForegroundColor Yellow }
    503 { Write-Host '  HTTP 503 = rate-limited or overloaded. Retry in a minute.' -ForegroundColor Yellow }
    504 { Write-Host "  HTTP 504 = request exceeded ${TimeoutSeconds}s." -ForegroundColor Yellow }
  }

  if ($lastResponse -and $lastResponse.Content) {
    Write-Host '  Response body:' -ForegroundColor Yellow
    try {
      ($lastResponse.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5)
    }
    catch {
      Write-Host $lastResponse.Content
    }
  }
  elseif ($lastError) {
    Write-Host "  Error: $($lastError.Exception.Message)" -ForegroundColor Yellow
  }

  exit 1
}

# -----------------------------------------------------------------------------
# Response shape validation
# -----------------------------------------------------------------------------
#
# AC 8 requires "a valid JSON answer" — by the seed contract that is exactly
# `{ "answer": "<string>" }`. We assert:
#   1. Body parses as JSON.
#   2. Top-level is an object.
#   3. `answer` field is present, is a string, and is non-empty.

$body = $null
try {
  $body = $lastResponse.Content | ConvertFrom-Json -ErrorAction Stop
}
catch {
  Write-Error "Response body is not valid JSON: $($_.Exception.Message)"
  Write-Host '  Raw body:' -ForegroundColor Yellow
  Write-Host $lastResponse.Content
  exit 1
}

if ($body -isnot [pscustomobject]) {
  Write-Error "JSON root must be an object, got $($body.GetType().Name)."
  exit 1
}

if (-not ($body.PSObject.Properties.Name -contains 'answer')) {
  $keys = ($body.PSObject.Properties.Name | Sort-Object) -join ', '
  Write-Error "Response object has no 'answer' field. Keys: [$keys]"
  exit 1
}

$answer = $body.answer
if ($null -eq $answer -or $answer -isnot [string]) {
  $type = if ($null -eq $answer) { 'null' } else { $answer.GetType().Name }
  Write-Error "'answer' field must be a string, got $type."
  exit 1
}

if ([string]::IsNullOrWhiteSpace($answer)) {
  Write-Error "'answer' field is empty/whitespace-only."
  Write-Host '  Raw body:' -ForegroundColor Yellow
  Write-Host ($lastResponse.Content)
  exit 1
}

# -----------------------------------------------------------------------------
# Success
# -----------------------------------------------------------------------------

$preview = ($answer -split "`n")[0]
if ($preview.Length -gt 200) {
  $preview = $preview.Substring(0, 197) + '...'
}

Write-Host ''
Write-Host '>> Smoke test PASSED.' -ForegroundColor Green
Write-Host "   Endpoint:      $ProbeUrl"
Write-Host '   HTTP status:   200 OK'
Write-Host '   Wire shape:    { "answer": <non-empty string> } ✅'
Write-Host "   Answer:        $($answer.Length) chars | $preview"
Write-Host ''

exit 0
