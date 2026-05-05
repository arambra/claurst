# Client Access Guide — claurst `/ask` Endpoint

A synchronous REST service for generating JSONata mapping expressions from
sample input / output JSON pairs (and for any other one-shot question that
benefits from a tool-augmented LLM).

This document is for third-party clients integrating against the hosted
`/ask` endpoint. It does **not** cover deployment, infrastructure, or how
the service is built — only how to call it.

---

## 1. Endpoint

| Field            | Value                                                                              |
|------------------|------------------------------------------------------------------------------------|
| Base URL         | `https://claurst-ask.salmonbeach-846c624f.canadacentral.azurecontainerapps.io`     |
| Path             | `/ask`                                                                             |
| Method           | `POST`                                                                             |
| Required header  | `X-API-Key: <your-api-key>`                                                        |
| Required header  | `Content-Type: application/json`                                                   |
| Request body     | `{ "question": "<your prompt as a single string>" }`                               |
| Response body    | `{ "answer": "<the model's response as a single string>" }`                        |
| Response codes   | `200` success · `401` bad/missing key · `400` malformed body · `5xx` see §6        |

The endpoint is **stateless** — every request is independent; there are no
sessions, no conversation history, no cookies.

## 2. Authentication

Obtain your `X-API-Key` value from the service operator. The key is a long
opaque string (treat it like a password):

- Send it on every request in the `X-API-Key` header.
- Do not embed it in client-side code that ships to end users — keep it
  on a backend you control.
- If the key leaks, request a rotation from the operator.

A request with no key (or the wrong key) returns `401 Unauthorized` with
a JSON body and a `WWW-Authenticate` header.

## 3. Request limits

| Limit                          | Value         | Notes                                             |
|--------------------------------|---------------|---------------------------------------------------|
| Maximum response time          | **240 s**     | Hard ingress timeout. Slower replies are aborted. |
| Practical request body size    | ~1 MB         | Container Apps ingress default.                   |
| Concurrency                    | low           | Single replica. Plan for serialised execution.    |
| Tool surface inside the loop   | read-only     | `web_fetch` + `todo` + LLM reasoning only.        |

Typical end-to-end latency for a JSONata-generation request with a few KB
of context is **5 – 60 seconds**. Configure your HTTP client with a
timeout of at least 240 s.

## 4. Generating a JSONata expression

The service has no special "JSONata mode" — it accepts a single
`question` string and returns a single `answer` string. To generate a
JSONata mapping you pose the prompt yourself, embedding the input and
expected-output JSON inline.

### 4.1 Recommended prompt template

```
Generate a JSONata expression that transforms the INPUT JSON into the OUTPUT JSON.
Return ONLY the JSONata expression. No backticks. No prose. The first character must be valid JSONata.

INPUT JSON:
<paste input JSON here>

OUTPUT JSON:
<paste expected output JSON here>
```

The `Return ONLY …` clause is load-bearing: without it the model often
wraps the expression in a Markdown fence or surrounds it with prose. If
you still receive prose-padded output, add a stricter constraint:

```
The response must be parseable by a JSONata engine without any preprocessing.
Do not output anything else.
```

### 4.2 What the model returns

The `answer` field is a plain string — the JSONata expression itself.
Example:

```json
{
  "answer": "{ \"po_number\": header.purchase_order_number, \"total_qty\": $sum(line_items.quantity) }"
}
```

The expression is ready to feed into any JSONata runtime (`jsonata-js`,
the JSONata Exerciser, the `jsonata` npm package, the `jsonata-python`
port, etc.).

### 4.3 Saving the result

If you want the expression on disk, pipe the `answer` field directly to
a `.jsonata` file. See §5 for language-specific snippets.

## 5. Examples

All examples assume the following environment variables:

```
CLAURST_URL=https://claurst-ask.salmonbeach-846c624f.canadacentral.azurecontainerapps.io
CLAURST_API_KEY=<your key>
```

### 5.1 curl

```bash
QUESTION=$(cat <<'EOF'
Generate a JSONata expression that transforms the INPUT JSON into the OUTPUT JSON.
Return ONLY the JSONata expression. No backticks. No prose.

INPUT JSON:
$(cat input.json)

OUTPUT JSON:
$(cat output.json)
EOF
)

jq -n --arg q "$QUESTION" '{question:$q}' | curl -sS -X POST "$CLAURST_URL/ask" \
    -H "X-API-Key: $CLAURST_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    --max-time 300 | jq -r .answer
```

### 5.2 PowerShell 7+

```powershell
$inputJson  = Get-Content input.json  -Raw
$outputJson = Get-Content output.json -Raw

$question = @"
Generate a JSONata expression that transforms the INPUT JSON into the OUTPUT JSON.
Return ONLY the JSONata expression. No backticks. No prose.

INPUT JSON:
$inputJson

OUTPUT JSON:
$outputJson
"@

$body = @{ question = $question } | ConvertTo-Json -Depth 20 -Compress

$resp = Invoke-RestMethod `
    -Method  Post `
    -Uri     "$env:CLAURST_URL/ask" `
    -Headers @{ 'X-API-Key' = $env:CLAURST_API_KEY } `
    -ContentType 'application/json' `
    -Body    $body `
    -TimeoutSec 300

$resp.answer | Set-Content -Path mapping.jsonata -Encoding UTF8
```

### 5.3 Python (`requests`)

```python
import json, os, requests, pathlib

URL = os.environ["CLAURST_URL"] + "/ask"
KEY = os.environ["CLAURST_API_KEY"]

input_json  = pathlib.Path("input.json").read_text(encoding="utf-8")
output_json = pathlib.Path("output.json").read_text(encoding="utf-8")

question = (
    "Generate a JSONata expression that transforms the INPUT JSON into "
    "the OUTPUT JSON. Return ONLY the JSONata expression. No backticks. "
    "No prose.\n\n"
    f"INPUT JSON:\n{input_json}\n\n"
    f"OUTPUT JSON:\n{output_json}\n"
)

resp = requests.post(
    URL,
    headers={"X-API-Key": KEY, "Content-Type": "application/json"},
    json={"question": question},
    timeout=300,
)
resp.raise_for_status()
expression = resp.json()["answer"]
pathlib.Path("mapping.jsonata").write_text(expression, encoding="utf-8")
print(expression)
```

### 5.4 Node.js (`fetch`, Node 18+)

```javascript
import { readFile, writeFile } from "node:fs/promises";

const url = `${process.env.CLAURST_URL}/ask`;
const key = process.env.CLAURST_API_KEY;

const [input, output] = await Promise.all([
    readFile("input.json",  "utf8"),
    readFile("output.json", "utf8"),
]);

const question = [
    "Generate a JSONata expression that transforms the INPUT JSON into the OUTPUT JSON.",
    "Return ONLY the JSONata expression. No backticks. No prose.",
    "",
    "INPUT JSON:", input,
    "",
    "OUTPUT JSON:", output,
].join("\n");

const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), 300_000);

const resp = await fetch(url, {
    method:  "POST",
    headers: { "X-API-Key": key, "Content-Type": "application/json" },
    body:    JSON.stringify({ question }),
    signal:  controller.signal,
});
clearTimeout(timer);

if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${await resp.text()}`);
const { answer } = await resp.json();
await writeFile("mapping.jsonata", answer, "utf8");
console.log(answer);
```

## 6. Error responses

| HTTP status | Meaning                                              | What to do                                                         |
|-------------|------------------------------------------------------|--------------------------------------------------------------------|
| `200`       | Success — `answer` field contains the model output.  | Use the value.                                                     |
| `400`       | Request body missing or invalid.                     | Verify the JSON body has a non-empty `question` string.            |
| `401`       | `X-API-Key` missing or doesn't match server's value. | Recheck the key. Watch for trailing whitespace.                    |
| `413`       | Question (with embedded JSON) exceeded the model context window. | Trim the input/output samples before sending.            |
| `502`       | Upstream LLM error.                                  | Retry with exponential backoff. Check service operator if persistent. |
| `503`       | Upstream rate-limited.                               | Retry with exponential backoff (seconds, not minutes).             |
| Connection timeout (240 s) | The agentic loop exceeded the ingress timeout. | Simplify the question, or split the work across smaller calls. |

Errors return JSON of the shape `{ "error": "<short code>", "message": "<human-readable>" }`. Always read both fields when logging.

## 7. Operational notes

- The service runs on a **single replica with no auto-scale**. Plan for
  one in-flight request at a time; queue your own load if you need
  parallelism.
- The service is **stateless**. Don't rely on any side effect of an
  earlier call.
- The model is **DeepSeek** behind an Anthropic-compatible API. Quality,
  determinism, and timing characteristics follow that model — not Claude
  or OpenAI.
- The tool surface inside the agentic loop is **read-only**: `web_fetch`,
  `todo`, and pure LLM reasoning. There is no shell, no file write, no
  filesystem inside the loop. Phrase questions accordingly.
- Output is **not deterministic**. The same prompt may produce slightly
  different JSONata expressions across calls. If you need a single
  canonical mapping, persist the first acceptable result.

## 8. Quick smoke test

```powershell
# PowerShell, replace with your key
$resp = Invoke-RestMethod `
    -Method Post `
    -Uri    "https://claurst-ask.salmonbeach-846c624f.canadacentral.azurecontainerapps.io/ask" `
    -Headers @{ 'X-API-Key' = '<your key>' } `
    -ContentType 'application/json' `
    -Body '{"question":"Reply with the literal string OK and nothing else."}' `
    -TimeoutSec 300
$resp.answer        # → "OK"
```

If the smoke test returns `OK` (or close to it), the endpoint is healthy
and your key is correct.
