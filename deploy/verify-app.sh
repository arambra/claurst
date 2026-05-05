#!/usr/bin/env bash
# verify-app.sh — confirm the deployed Container App is running and reachable
# via its public HTTPS FQDN.
#
# Satisfies **AC 5 Sub-AC 4**: "Verify the deployed Container App is running
# and reachable via its public HTTPS FQDN."
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
# Why this exists separately from provision-app.sh:
#
#   provision-app.sh ends by printing the FQDN and a curl one-liner — useful,
#   but it doesn't actually probe the endpoint. A green provisioning call
#   means "ARM accepted the resource definition", which is necessary but not
#   sufficient: an image that crash-loops on startup, a container that binds
#   the wrong port, or an ingress that hasn't finished propagating to the
#   front door all produce a healthy ARM resource that fails real traffic.
#   verify-app.sh is the explicit "prove the public surface works" gate the
#   Seed's exit_conditions.azure_deployed clause demands.
#
# Read-only by design: this script never mutates state. It is safe to run
# from CI as a release gate, from an operator's laptop as a smoke test, or
# from an external monitoring job. Re-running it is idempotent.
#
# What this script does, in order:
#   1. Confirms `az` is installed, the caller is logged in, and the
#      `containerapp` extension is current. (Same preflight every other
#      deploy script enforces, kept identical so a typo here matches the
#      typo error message there.)
#   2. Resolves the Container App's resource record. A missing record means
#      provision-app.sh hasn't run; we fail with a pointer at that script
#      rather than letting later steps produce noisier errors.
#   3. Asserts properties.provisioningState == "Succeeded". Any other value
#      (`Failed`, `InProgress`, `Canceled`) means the latest revision didn't
#      come up; logging is the operator's next step.
#   4. Asserts properties.runningStatus == "Running". This is the platform's
#      composite signal: the latest active revision has a healthy replica
#      pool. `Stopped` / `Suspended` / `Disabled` here all fail the gate.
#   5. Lists revision replicas and confirms at least one is in
#      `runningState == "Running"`. Some short windows (image pulling, app
#      starting, max-replicas being lowered) leave runningStatus="Running"
#      momentarily before any replica is actually serving — failing those
#      windows surfaces a clearer "no replica yet" error than waiting for
#      the HTTPS probe to time out.
#   6. Resolves the public FQDN from
#      properties.configuration.ingress.fqdn. Asserts ingress is external —
#      an `internal` ingress would never satisfy "publicly reachable".
#   7. Performs an actual HTTPS request against `https://<FQDN>/ask` with
#      no X-API-Key header. The Seed-mandated auth contract returns
#      **401 Unauthorized** for any request missing or carrying a wrong
#      X-API-Key (see crates/cli/src/serve_auth.rs and AC 2). A 401 here
#      proves end-to-end:
#        • DNS resolves the per-app subdomain.
#        • Container Apps' managed front door terminates TLS for it.
#        • The container is bound to TARGET_PORT and accepts connections.
#        • The auth middleware is loaded and answering.
#      Any other response (non-2xx that isn't 401, or a connection-level
#      failure) fails the gate.
#   8. Prints a success summary with the FQDN and ready-to-paste curl
#      commands the operator can use to drive a real /ask request.
#
# Required env vars (or pass on the command line — see Usage):
#   AZ_RESOURCE_GROUP    Resource group containing the Container App
#                        (must match provision-app.sh).
#   AZ_CONTAINERAPP      Name of the Container App (e.g. claurst-ask).
#
# Optional env vars:
#   PROBE_TIMEOUT_SECONDS Per-request timeout for the HTTPS reachability
#                         probe (default: 30). Should comfortably exceed
#                         normal cold-start latency without exceeding the
#                         platform's 240 s ingress idle timeout. The probe
#                         doesn't run the agentic loop (it stops at auth)
#                         so 30 s is well over the realistic ceiling.
#   PROBE_RETRIES         Number of probe retries before failing
#                         (default: 12). The platform front door can take
#                         60-90 s after `provision-app.sh` to start
#                         accepting traffic for a brand-new revision; the
#                         retry budget covers that without masking real
#                         deployment failures.
#   PROBE_DELAY_SECONDS   Sleep between retries (default: 5). Combined
#                         with PROBE_RETRIES this gives ~60 s of
#                         tolerance for cold-start, which is the
#                         observed worst case for a fresh revision.
#
# Usage:
#   AZ_RESOURCE_GROUP=rg-claurst \
#   AZ_CONTAINERAPP=claurst-ask \
#     ./deploy/verify-app.sh
#
# Exit status:
#   0  app exists, provisioned, running, ≥1 replica running, ingress
#      external, FQDN responds 401 to an unauthenticated POST /ask.
#   1  any of: app missing, provisioning failed, no running replica,
#      ingress not external, FQDN unreachable, FQDN responds with
#      something other than 401 to the unauthenticated probe.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${AZ_RESOURCE_GROUP:?AZ_RESOURCE_GROUP must be set (e.g. rg-claurst)}"
: "${AZ_CONTAINERAPP:?AZ_CONTAINERAPP must be set (e.g. claurst-ask)}"

PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-30}"
PROBE_RETRIES="${PROBE_RETRIES:-12}"
PROBE_DELAY_SECONDS="${PROBE_DELAY_SECONDS:-5}"

# Container App name rules: 2-32 chars, lowercase alphanumeric + hyphens, must
# start and end alphanumeric. Catching this client-side avoids a 5-second
# round-trip to ARM just to learn the name is invalid (mirrors provision-app.sh
# and configure-ingress.sh).
if [[ ! "${AZ_CONTAINERAPP}" =~ ^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$ ]]; then
  echo "AZ_CONTAINERAPP='${AZ_CONTAINERAPP}' is invalid: must be 2-32 chars, lowercase alphanumeric or hyphens, starting and ending alphanumeric." >&2
  exit 1
fi

# Probe-knob sanity: integers only, retries must allow at least one attempt,
# delay/timeout must be non-negative.
if [[ ! "${PROBE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( PROBE_TIMEOUT_SECONDS < 1 )); then
  echo "PROBE_TIMEOUT_SECONDS='${PROBE_TIMEOUT_SECONDS}' is invalid: must be a positive integer." >&2
  exit 1
fi
if [[ ! "${PROBE_RETRIES}" =~ ^[0-9]+$ ]] || (( PROBE_RETRIES < 1 )); then
  echo "PROBE_RETRIES='${PROBE_RETRIES}' is invalid: must be a positive integer." >&2
  exit 1
fi
if [[ ! "${PROBE_DELAY_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "PROBE_DELAY_SECONDS='${PROBE_DELAY_SECONDS}' is invalid: must be a non-negative integer." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Preflight: az CLI present, authenticated, containerapp extension installed
# -----------------------------------------------------------------------------

if ! command -v az >/dev/null 2>&1; then
  echo "az CLI not found on PATH — install from https://aka.ms/InstallAzureCLI" >&2
  exit 1
fi

# `curl` is the portable HTTPS probe used by every deploy verifier in this
# repo. The probe doesn't need any specific curl extension — just `-sS`
# (silent + show errors), `-X POST`, `-w '%{http_code}'` to capture the
# status code, and `-o` to discard the body. Failing here points the
# operator at the standard install path on the platforms we support.
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found on PATH — install your distribution's curl package (e.g. apt install curl)." >&2
  exit 1
fi

if ! az account show --output none 2>/dev/null; then
  echo "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first." >&2
  exit 1
fi

SUBSCRIPTION_NAME="$(az account show --query name --output tsv)"
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

echo ">> Active subscription: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"
echo ">> Container App:       ${AZ_CONTAINERAPP} (group: ${AZ_RESOURCE_GROUP})"
echo ">> Probe budget:        ${PROBE_RETRIES} attempts × ${PROBE_DELAY_SECONDS}s delay (per-call timeout: ${PROBE_TIMEOUT_SECONDS}s)"

# `az containerapp` lives in the `containerapp` extension. Modern Azure CLI
# auto-installs on first use; explicit `extension add` here makes the script
# work on older `az` versions too (matches every other deploy script).
echo ">> Ensuring 'containerapp' Azure CLI extension is installed..."
if [ -z "$(az extension list --query "[?name=='containerapp'].name | [0]" -o tsv 2>/dev/null)" ]; then
    az extension add --name containerapp --only-show-errors --yes --output none
fi

# -----------------------------------------------------------------------------
# Step 1: confirm the Container App exists
# -----------------------------------------------------------------------------
#
# `az containerapp show` is a single round-trip that returns the entire
# resource record. We capture it once and `jq`-style query individual fields
# below — cheaper than three separate `--query` calls and atomic against
# any state change happening mid-script. (We use `--query` against the
# already-fetched JSON via shell variables rather than re-calling `az`.)
echo ""
echo ">> [1/4] Resolving Container App resource..."

APP_JSON="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --output json 2>/dev/null || true)"

if [[ -z "${APP_JSON}" ]]; then
  echo "Container App '${AZ_CONTAINERAPP}' not found in resource group '${AZ_RESOURCE_GROUP}'." >&2
  echo "Run deploy/provision-app.sh first to create the app, then re-run this script to verify it." >&2
  exit 1
fi

# Helper: extract a JSON path via az's bundled `--query`. We pipe APP_JSON
# back through `az` because the script can't depend on `jq` being installed
# on the operator's box (we only require curl + az). The `-r` flag would
# strip quotes if jq existed; the equivalent with az is `--output tsv`,
# which we get by sending the JSON through `python -c` … but that's also
# not guaranteed. So instead, we use `az containerapp show --query` for
# each field — three round-trips, one per field. Cheap (~150 ms each)
# and depends on tools we already require.
PROVISIONING_STATE="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.provisioningState \
  --output tsv)"

RUNNING_STATUS="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.runningStatus \
  --output tsv 2>/dev/null || true)"

INGRESS_FQDN="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.ingress.fqdn \
  --output tsv 2>/dev/null || true)"

INGRESS_EXTERNAL="$(az containerapp show \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query properties.configuration.ingress.external \
  --output tsv 2>/dev/null || true)"

echo "   provisioningState: ${PROVISIONING_STATE}"
echo "   runningStatus:     ${RUNNING_STATUS:-<unset>}"
echo "   ingress.external:  ${INGRESS_EXTERNAL:-<unset>}"
echo "   ingress.fqdn:      ${INGRESS_FQDN:-<unset>}"

# -----------------------------------------------------------------------------
# Step 2: assert provisioning + running status
# -----------------------------------------------------------------------------
#
# `provisioningState` is the ARM-level signal that the latest revision
# definition was accepted and the platform finished applying it. Anything
# other than `Succeeded` means provision-app.sh / configure-ingress.sh /
# configure-runtime.sh produced a definition the platform couldn't
# materialise — that's a deploy-time bug, not a runtime hiccup.
#
# `runningStatus` is the data-plane signal — does the platform consider
# the app live? `Running` is the only state that admits traffic; the
# others (`Stopped`, `Suspended`, `Disabled`, `Progressing`) either
# require operator intervention or a retry after the platform finishes
# its own state change.
echo ""
echo ">> [2/4] Asserting Container App state..."

if [[ "${PROVISIONING_STATE}" != "Succeeded" ]]; then
  echo "Container App provisioningState is '${PROVISIONING_STATE}' (expected 'Succeeded')." >&2
  echo "Inspect the latest deploy:" >&2
  echo "  az containerapp show -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} --query properties" >&2
  echo "  az containerapp logs show -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} --type system --follow" >&2
  exit 1
fi

# `runningStatus` was added relatively late to the API; older `az` versions
# return an empty string rather than the field. Treat empty-string as
# "platform didn't surface the field" (best-effort) and rely on the replica
# probe in Step 3 for the authoritative answer. Anything non-empty other
# than "Running" is a hard failure.
if [[ -n "${RUNNING_STATUS}" && "${RUNNING_STATUS}" != "Running" ]]; then
  echo "Container App runningStatus is '${RUNNING_STATUS}' (expected 'Running')." >&2
  echo "If the app was deliberately stopped, restart with:" >&2
  echo "  az containerapp revision restart -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} --revision <name>" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 3: confirm at least one replica is actually running
# -----------------------------------------------------------------------------
#
# `runningStatus == "Running"` can briefly precede any replica actually
# being up (image pulling, container starting). The replica list is the
# authoritative answer to "is something serving on this revision?".
#
# Resolution path:
#   1. Find the latest active revision (sort by createdTime, take the last).
#   2. List its replicas.
#   3. Count the ones in runningState == "Running".
#
# A brand-new revision can have no replicas yet (the platform is still
# materialising the first one). We treat that as a soft failure — the
# Sub-AC requires the app to BE running, not that it could eventually be.
echo ""
echo ">> [3/4] Confirming a replica is running..."

LATEST_REVISION="$(az containerapp revision list \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query "sort_by([?properties.active], &properties.createdTime) | [-1].name" \
  --output tsv 2>/dev/null || true)"

if [[ -z "${LATEST_REVISION}" ]]; then
  echo "No active revision found for Container App '${AZ_CONTAINERAPP}'." >&2
  echo "Run deploy/provision-app.sh to deploy a revision, or check the portal for a failed deployment." >&2
  exit 1
fi

echo "   latest active revision: ${LATEST_REVISION}"

# `replica list --revision` is the canonical lookup. `properties.runningState`
# distinguishes between Pending (image pulling), Running (serving), Failed
# (crash-looped), Terminated (decommissioned). Only Running counts.
RUNNING_REPLICA_COUNT="$(az containerapp replica list \
  --name "${AZ_CONTAINERAPP}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --revision "${LATEST_REVISION}" \
  --query "length([?properties.runningState == 'Running'])" \
  --output tsv 2>/dev/null || true)"

# Some `az` versions return the count as `0` and others as empty when no
# replicas match. Normalise both to integer 0.
if [[ -z "${RUNNING_REPLICA_COUNT}" || ! "${RUNNING_REPLICA_COUNT}" =~ ^[0-9]+$ ]]; then
  RUNNING_REPLICA_COUNT=0
fi

echo "   replicas in 'Running' state: ${RUNNING_REPLICA_COUNT}"

if (( RUNNING_REPLICA_COUNT < 1 )); then
  echo "No replica is in 'Running' state on the latest active revision." >&2
  echo "Inspect replica details and container logs:" >&2
  echo "  az containerapp replica list -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} --revision ${LATEST_REVISION} -o table" >&2
  echo "  az containerapp logs show -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} --revision ${LATEST_REVISION} --follow" >&2
  exit 1
fi

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
# DEEPSEEK_API_KEY, and proves:
#   • DNS for <app>.<env-suffix>.azurecontainerapps.io resolves.
#   • Container Apps' managed reverse proxy terminates TLS for it.
#   • The pod's container is bound and accepting requests.
#   • The auth middleware is loaded and producing the right rejection.

if [[ -z "${INGRESS_FQDN}" ]]; then
  echo "Container App has no public ingress FQDN — ingress is disabled or hasn't propagated." >&2
  echo "Run deploy/configure-ingress.sh to enable external HTTPS ingress." >&2
  exit 1
fi

# `ingress.external` is reported as the literal string "true" / "false" via
# `--query --output tsv`. Anything else (empty, "True", JSON `true`) means
# the API didn't surface the field; we err on the safe side and require the
# explicit lowercase "true" the canonical response uses.
if [[ "${INGRESS_EXTERNAL}" != "true" ]]; then
  echo "Container App ingress is not external (ingress.external = '${INGRESS_EXTERNAL}')." >&2
  echo "Run deploy/configure-ingress.sh to switch ingress visibility to 'external'." >&2
  exit 1
fi

PROBE_URL="https://${INGRESS_FQDN}/ask"
echo ""
echo ">> [4/4] Probing ${PROBE_URL} (expecting 401 from unauthenticated POST)..."

# Probe loop:
#   • -sS                   silent except for errors (so connection-level
#                           failures still print to stderr)
#   • -X POST               match the endpoint's only valid verb
#   • -H 'Content-Type:...' the body is JSON; without this header the
#                           handler might short-circuit before reaching
#                           auth middleware (a malformed request is also
#                           proof of reachability, but matching the real
#                           request shape gives the most realistic probe).
#   • -d '{"question":"."}' minimal valid body — the auth middleware
#                           rejects before the handler parses the body,
#                           so this just has to be syntactically valid.
#   • --max-time            per-attempt timeout. Defaults to 30s; the
#                           probe never reaches the agentic loop, so
#                           this is comfortably above any realistic
#                           response time.
#   • -o /dev/null          discard body — we only care about the code.
#   • -w '%{http_code}'     emit just the integer status code on stdout.

attempt=0
last_code=""
last_curl_exit=0
while (( attempt < PROBE_RETRIES )); do
  attempt=$((attempt + 1))
  set +e
  last_code="$(curl -sS -X POST "${PROBE_URL}" \
    -H 'Content-Type: application/json' \
    -d '{"question":"verify-app probe"}' \
    --max-time "${PROBE_TIMEOUT_SECONDS}" \
    -o /dev/null \
    -w '%{http_code}' 2>/dev/null)"
  last_curl_exit=$?
  set -e

  if (( last_curl_exit == 0 )) && [[ "${last_code}" == "401" ]]; then
    echo "   attempt ${attempt}/${PROBE_RETRIES}: 401 (expected) — endpoint reachable, auth wiring confirmed."
    break
  fi

  if (( last_curl_exit == 0 )); then
    echo "   attempt ${attempt}/${PROBE_RETRIES}: HTTP ${last_code} (waiting for 401)"
  else
    # curl exit codes: 6 = couldn't resolve host, 7 = couldn't connect,
    # 28 = operation timeout, 35 = SSL handshake. All four are the
    # signature of "front door not yet ready"; retry is correct.
    echo "   attempt ${attempt}/${PROBE_RETRIES}: curl exit ${last_curl_exit} (front door not yet reachable)"
  fi

  if (( attempt < PROBE_RETRIES )); then
    sleep "${PROBE_DELAY_SECONDS}"
  fi
done

if (( last_curl_exit != 0 )) || [[ "${last_code}" != "401" ]]; then
  echo "" >&2
  echo "Reachability probe FAILED after ${PROBE_RETRIES} attempt(s)." >&2
  if (( last_curl_exit != 0 )); then
    echo "  Last curl exit code: ${last_curl_exit} (connection-level failure — see 'man curl' EXIT CODES)." >&2
  else
    echo "  Last HTTP status:    ${last_code} (expected 401)." >&2
    case "${last_code}" in
      000)  echo "  HTTP 000 = no response received; container probably crash-looped or never bound the port." >&2 ;;
      403)  echo "  HTTP 403 typically means the front door rejected the request before reaching the container." >&2 ;;
      404)  echo "  HTTP 404 means the route /ask is not wired in this binary build." >&2 ;;
      502)  echo "  HTTP 502 means Container Apps reached the container but it did not answer (port mismatch or crash)." >&2 ;;
      503)  echo "  HTTP 503 means no replica is currently serving (cold-start or all replicas unhealthy)." >&2 ;;
    esac
  fi
  echo "" >&2
  echo "Diagnostic next steps:" >&2
  echo "  az containerapp logs show -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} --revision ${LATEST_REVISION} --follow" >&2
  echo "  az containerapp logs show -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} --type system --follow" >&2
  echo "  az containerapp replica list -n ${AZ_CONTAINERAPP} -g ${AZ_RESOURCE_GROUP} --revision ${LATEST_REVISION} -o table" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

cat <<EOF

>> Verification PASSED.
   Container App:        ${AZ_CONTAINERAPP}
   Resource group:       ${AZ_RESOURCE_GROUP}
   Latest revision:      ${LATEST_REVISION}
   Running replicas:     ${RUNNING_REPLICA_COUNT}
   Public FQDN:          https://${INGRESS_FQDN}
   /ask probe (no key):  401 Unauthorized (expected) ✅

   Drive a real /ask request — supply your CLAURST_API_KEY and try one:

   curl -sSf -X POST https://${INGRESS_FQDN}/ask \\
     -H "X-API-Key: \${CLAURST_API_KEY}" \\
     -H 'Content-Type: application/json' \\
     -d '{"question":"What is the capital of France?"}'

   Tail logs while you exercise it:

   az containerapp logs show \\
     --name ${AZ_CONTAINERAPP} \\
     --resource-group ${AZ_RESOURCE_GROUP} \\
     --revision ${LATEST_REVISION} \\
     --follow

EOF
