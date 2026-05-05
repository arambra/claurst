#!/usr/bin/env bash
# smoke-test-ask.sh — drive the canonical AC 8 curl against a deployed
# Container App and assert it returns a valid JSON answer.
#
# Satisfies **AC 8**: "curl -H 'X-API-Key: ...' -d '{"question":"..."}'
# https://<app>.azurecontainerapps.io/ask returns a valid JSON answer".
#
# This is the end-to-end exit-condition gate the Seed declares as
# `endpoint_functional`: the deployed image must accept an authenticated POST
# /ask request, run it through the agentic loop, and respond with the
# `{ "answer": "..." }` JSON envelope `cc_http::handlers::ask_handler`
# produces. Anything else — non-2xx, malformed JSON, missing `answer` field,
# empty answer string — fails the gate.
#
# Where this fits in the deploy pipeline:
#
#   provision-acr      → registry exists                       (AC 5)
#   provision-env      → Container Apps environment exists     (AC 5)
#   provision-identity → user-assigned managed identity exists (AC 5)
#   push-image         → image tag pushed to ACR               (AC 6)
#   provision-app      → Container App created/updated         (AC 5)
#   configure-runtime  → ingress + secrets + env vars          (AC 5)
#   verify-app         → 401 probe (no X-API-Key)               (AC 5)
#   ▶ smoke-test-ask ◀ → 200 probe with X-API-Key + answer JSON (AC 8)
#
# Why this is distinct from `verify-app.sh`:
#   `verify-app.sh` proves the public surface is reachable — DNS resolves,
#   TLS terminates, the auth middleware is loaded — by sending an
#   *unauthenticated* POST and asserting 401. That confirms the wire is
#   live but never exercises the agentic loop.
#
#   `smoke-test-ask.sh` is the one step beyond: it sends an *authenticated*
#   request and asserts the response body matches the canonical
#   `{ "answer": <non-empty-string> }` shape. That proves:
#     * The X-API-Key middleware accepts the configured CLAURST_API_KEY.
#     * The `cc_http::ask_handler` is reachable behind the auth gate.
#     * `cc-query::run_query_loop` runs to completion without error.
#     * The cc-api client successfully reaches DeepSeek's
#       Anthropic-compatible endpoint with the configured DEEPSEEK_API_KEY.
#     * The response wire format is exactly the locked-in `{ "answer": "..." }`
#       envelope the seed contract requires.
#
# Read-only by design — never mutates Azure state. Safe to run from CI as a
# post-deploy gate, from an operator's laptop after `configure-runtime.sh`,
# or as an external monitoring job.
#
# Required env vars (or pass on the command line — see Usage):
#   APP_FQDN          Public FQDN of the Container App (e.g.
#                     claurst-ask.<env-suffix>.azurecontainerapps.io). Either
#                     pass this directly OR pass AZ_RESOURCE_GROUP +
#                     AZ_CONTAINERAPP and let the script resolve it via az.
#   CLAURST_API_KEY   The X-API-Key value the deployment was provisioned with
#                     — i.e. the same value passed to setup-secrets.sh /
#                     configure-runtime.sh.
#
# Optional env vars:
#   AZ_RESOURCE_GROUP    If set with AZ_CONTAINERAPP, the script resolves the
#                        FQDN via `az containerapp show`.
#   AZ_CONTAINERAPP      Container App name (resolved alongside AZ_RESOURCE_GROUP).
#   QUESTION             The question body sent to /ask (default: a deterministic
#                        question that should consistently elicit a non-empty
#                        answer from any general-purpose LLM).
#   PROBE_TIMEOUT_SECONDS Per-request timeout for the curl probe (default: 240).
#                        Matches the platform ingress idle timeout — the agentic
#                        loop has up to that long to complete.
#   PROBE_RETRIES        Number of probe retries before failing (default: 3).
#                        Covers transient upstream rate-limits / cold-start
#                        without masking real failures.
#   PROBE_DELAY_SECONDS  Delay between retries (default: 5).
#
# Usage:
#
#   # Direct: pass the FQDN explicitly
#   APP_FQDN=claurst-ask.salmonbay-12345.azurecontainerapps.io \
#   CLAURST_API_KEY=$(cat /path/to/saved-key) \
#     ./deploy/smoke-test-ask.sh
#
#   # Indirect: resolve the FQDN via az
#   AZ_RESOURCE_GROUP=rg-claurst \
#   AZ_CONTAINERAPP=claurst-ask \
#   CLAURST_API_KEY=$(cat /path/to/saved-key) \
#     ./deploy/smoke-test-ask.sh
#
# Exit status:
#   0  endpoint returned 200 with `{ "answer": "<non-empty-string>" }`.
#   1  any other outcome — non-2xx, missing/empty `answer`, malformed JSON,
#      connection failure, or invalid configuration.

set -euo pipefail

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

: "${CLAURST_API_KEY:?CLAURST_API_KEY must be set — pass the same value used in setup-secrets.sh}"

QUESTION="${QUESTION:-What is the capital of France? Reply in one short sentence.}"
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-240}"
PROBE_RETRIES="${PROBE_RETRIES:-3}"
PROBE_DELAY_SECONDS="${PROBE_DELAY_SECONDS:-5}"

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

# Inbound API key sanity: a literal-blank value would prove nothing — the
# auth middleware would reject it and we'd misdiagnose as a 401 scenario.
# Whitespace-only is also rejected because trim() inside the middleware does
# not happen and a whitespace key never matches the configured one.
if [[ -z "${CLAURST_API_KEY// /}" ]]; then
  echo "CLAURST_API_KEY must not be blank or whitespace-only." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Tool preflight
# -----------------------------------------------------------------------------

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found on PATH — install your distribution's curl package (e.g. apt install curl)." >&2
  exit 1
fi

# `python3` is the portable JSON parser used here. Every supported deploy
# host (Linux CI runners, macOS, WSL, modern Container Apps build agents)
# has it preinstalled. Avoiding `jq` keeps the script's tool-floor identical
# to the rest of `deploy/` (curl + python3 + az), which means an operator
# already running `verify-app.sh` doesn't need to install anything new.
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found on PATH — required for JSON-shape validation." >&2
  echo "Install your distribution's python3 package (e.g. apt install python3)." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Resolve the public FQDN
# -----------------------------------------------------------------------------
#
# Two acceptable inputs:
#   * APP_FQDN passed directly — useful for callers that don't have az
#     installed (e.g. external monitoring) or that already know the FQDN.
#   * AZ_RESOURCE_GROUP + AZ_CONTAINERAPP — the script asks `az containerapp
#     show` for `properties.configuration.ingress.fqdn`. Mirrors how
#     `verify-app.sh` resolves the FQDN, so an operator who's already
#     running provision-app.sh / verify-app.sh doesn't have to learn a new
#     env-var contract.

if [[ -z "${APP_FQDN:-}" ]]; then
  if [[ -n "${AZ_RESOURCE_GROUP:-}" && -n "${AZ_CONTAINERAPP:-}" ]]; then
    if ! command -v az >/dev/null 2>&1; then
      echo "az CLI not found — either install it or pass APP_FQDN directly." >&2
      exit 1
    fi
    if ! az account show --output none 2>/dev/null; then
      echo "Not logged in to Azure — either 'az login' first or pass APP_FQDN directly." >&2
      exit 1
    fi
    APP_FQDN="$(az containerapp show \
      --name "${AZ_CONTAINERAPP}" \
      --resource-group "${AZ_RESOURCE_GROUP}" \
      --query properties.configuration.ingress.fqdn \
      --output tsv 2>/dev/null || true)"
    if [[ -z "${APP_FQDN}" ]]; then
      echo "Could not resolve FQDN for Container App '${AZ_CONTAINERAPP}' in '${AZ_RESOURCE_GROUP}'." >&2
      echo "Confirm the app exists and ingress is enabled (run deploy/verify-app.sh first)." >&2
      exit 1
    fi
  else
    echo "APP_FQDN is not set, and AZ_RESOURCE_GROUP/AZ_CONTAINERAPP weren't provided either." >&2
    echo "Pass either APP_FQDN directly, or both AZ_RESOURCE_GROUP and AZ_CONTAINERAPP for az resolution." >&2
    exit 1
  fi
fi

# Reject anything that doesn't look like a Container Apps FQDN: the script
# stitches `https://${APP_FQDN}/ask` so a raw URL or a path-bearing value
# would silently produce a malformed request.
if [[ ! "${APP_FQDN}" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
  echo "APP_FQDN='${APP_FQDN}' does not look like a bare hostname — strip the scheme/path and pass just the FQDN." >&2
  exit 1
fi

PROBE_URL="https://${APP_FQDN}/ask"

# Build the request body. We use python3 here (and not a string template)
# so a question containing quotes / backslashes / newlines round-trips
# through JSON encoding correctly. Any string value is acceptable — the
# handler trims and rejects only empty / whitespace-only.
REQUEST_BODY="$(python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"question": os.environ["QUESTION"]}))
' QUESTION="${QUESTION}")"

echo ">> Smoke-testing /ask against ${PROBE_URL}"
echo "   question:     ${QUESTION}"
echo "   timeout:      ${PROBE_TIMEOUT_SECONDS}s per attempt"
echo "   retry budget: ${PROBE_RETRIES} attempt(s) with ${PROBE_DELAY_SECONDS}s delay"
echo "   x-api-key:    *****${CLAURST_API_KEY: -4}    # last 4 chars only"

# -----------------------------------------------------------------------------
# Probe loop
# -----------------------------------------------------------------------------
#
# We capture body and status code in one curl call by writing the body to a
# temp file and printing only `%{http_code}` to stdout. That keeps the script
# robust against bodies large enough to pollute terminal output and lets
# python3 parse the body in a separate step.
#
# The retry budget covers two narrow situations:
#   1. Cold start — the first request after a fresh deploy can take longer
#      because the container is still pulling the image / initialising the
#      first replica. Container Apps gates traffic until the container binds
#      its port, so this is mostly absorbed by `verify-app.sh`'s retry loop;
#      we keep a small budget here as a safety net.
#   2. Upstream rate-limit — DeepSeek returns 429 occasionally; the agentic
#      loop maps that to a 503 from /ask. A retry usually clears it. We
#      *don't* retry indefinitely: a deployment with a wrong DEEPSEEK_API_KEY
#      should fail fast, not loop for half an hour.

BODY_FILE="$(mktemp -t claurst-ask-body-XXXXXX.json)"
trap 'rm -f "${BODY_FILE}"' EXIT

attempt=0
last_code=""
last_curl_exit=0
while (( attempt < PROBE_RETRIES )); do
  attempt=$((attempt + 1))

  # Drain previous attempt's body so the file holds only the latest response.
  : > "${BODY_FILE}"

  set +e
  last_code="$(curl -sS -X POST "${PROBE_URL}" \
    -H "X-API-Key: ${CLAURST_API_KEY}" \
    -H 'Content-Type: application/json' \
    --data-raw "${REQUEST_BODY}" \
    --max-time "${PROBE_TIMEOUT_SECONDS}" \
    -o "${BODY_FILE}" \
    -w '%{http_code}' 2>/dev/null)"
  last_curl_exit=$?
  set -e

  if (( last_curl_exit == 0 )) && [[ "${last_code}" == "200" ]]; then
    echo "   attempt ${attempt}/${PROBE_RETRIES}: 200 OK — validating response body…"
    break
  fi

  if (( last_curl_exit == 0 )); then
    echo "   attempt ${attempt}/${PROBE_RETRIES}: HTTP ${last_code} (expected 200)"
  else
    echo "   attempt ${attempt}/${PROBE_RETRIES}: curl exit ${last_curl_exit} (connection-level failure)"
  fi

  if (( attempt < PROBE_RETRIES )); then
    sleep "${PROBE_DELAY_SECONDS}"
  fi
done

# -----------------------------------------------------------------------------
# Failure diagnostics
# -----------------------------------------------------------------------------
#
# Surface as much actionable detail as possible without echoing the
# X-API-Key. The handler's error envelope is `{ "error": "...", "message":
# "..." }`; print that verbatim if the body parsed as JSON, otherwise emit
# the raw bytes so the operator can spot a non-JSON wall-of-text response
# (e.g. a Container Apps 502 page).

if (( last_curl_exit != 0 )) || [[ "${last_code}" != "200" ]]; then
  echo "" >&2
  echo "Smoke test FAILED after ${PROBE_RETRIES} attempt(s)." >&2

  if (( last_curl_exit != 0 )); then
    echo "  Last curl exit code: ${last_curl_exit} (connection-level failure — see 'man curl' EXIT CODES)." >&2
  else
    echo "  Last HTTP status:    ${last_code}" >&2
    case "${last_code}" in
      401) echo "  HTTP 401 = X-API-Key rejected. Confirm CLAURST_API_KEY matches setup-secrets.sh." >&2 ;;
      404) echo "  HTTP 404 = /ask route is not wired. Check the running image actually starts 'claude serve'." >&2 ;;
      413) echo "  HTTP 413 = context window exceeded. Shorten the question." >&2 ;;
      502) echo "  HTTP 502 = upstream model call failed. Confirm DEEPSEEK_API_KEY is correct and DeepSeek is reachable." >&2 ;;
      503) echo "  HTTP 503 = rate-limited or overloaded. Retry in a minute." >&2 ;;
      504) echo "  HTTP 504 = request exceeded ${PROBE_TIMEOUT_SECONDS}s. The agentic loop ran past the ingress deadline." >&2 ;;
    esac
    echo "  Response body:" >&2
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${BODY_FILE}" 2>/dev/null; then
      python3 -m json.tool "${BODY_FILE}" >&2
    else
      cat "${BODY_FILE}" >&2
      echo "" >&2
    fi
  fi
  exit 1
fi

# -----------------------------------------------------------------------------
# Response shape validation
# -----------------------------------------------------------------------------
#
# AC 8 requires "a valid JSON answer" — by the seed contract that is exactly
# `{ "answer": "<string>" }`, no extra fields, no nested object, no token
# counts, no tool traces. We assert:
#   1. Body parses as JSON.
#   2. Top-level is an object.
#   3. `answer` field is present and is a non-empty string.
# Anything else fails the gate.

VALIDATION_OUTPUT="$(python3 - "${BODY_FILE}" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, "rb") as fh:
        data = json.load(fh)
except json.JSONDecodeError as e:
    print(f"NOT_JSON {e.msg} at offset {e.pos}", end="")
    sys.exit(1)
except Exception as e:  # pragma: no cover — defensive
    print(f"READ_FAIL {e!r}", end="")
    sys.exit(1)

if not isinstance(data, dict):
    print(f"WRONG_TYPE root must be a JSON object, got {type(data).__name__}", end="")
    sys.exit(1)

if "answer" not in data:
    keys = sorted(data.keys())
    print(f"MISSING_FIELD root object has no `answer` field; keys: {keys}", end="")
    sys.exit(1)

answer = data["answer"]
if not isinstance(answer, str):
    print(f"WRONG_FIELD_TYPE `answer` must be a string, got {type(answer).__name__}", end="")
    sys.exit(1)

if not answer.strip():
    print("EMPTY_ANSWER `answer` field is empty/whitespace-only", end="")
    sys.exit(1)

# Success: print a compact preview (first line, trimmed to 200 chars) so the
# operator's terminal shows what the model actually said.
preview = answer.splitlines()[0] if answer.splitlines() else answer
if len(preview) > 200:
    preview = preview[:197] + "..."
print(f"OK {len(answer)} chars | {preview}", end="")
PY
)"

VALIDATION_EXIT=$?
if (( VALIDATION_EXIT != 0 )); then
  echo "" >&2
  echo "Response body validation FAILED." >&2
  echo "  ${VALIDATION_OUTPUT}" >&2
  echo "  Raw body:" >&2
  python3 -m json.tool "${BODY_FILE}" 2>/dev/null >&2 || cat "${BODY_FILE}" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Success
# -----------------------------------------------------------------------------

# `OK <len> chars | <preview>` — strip the leading "OK " and use the rest.
PREVIEW="${VALIDATION_OUTPUT#OK }"

cat <<EOF

>> Smoke test PASSED.
   Endpoint:      ${PROBE_URL}
   HTTP status:   200 OK
   Wire shape:    { "answer": <non-empty string> } ✅
   Answer:        ${PREVIEW}

   Tail logs while you exercise more requests:

   az containerapp logs show \\
     --name <app> --resource-group <rg> --follow

EOF
