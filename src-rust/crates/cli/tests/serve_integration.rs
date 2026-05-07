//! End-to-end integration tests for the production `POST /ask` endpoint.
//!
//! Sub-AC 4 (AC 1) — "Add integration tests covering the happy path
//! (valid key + question → 200 with answer JSON) and the auth failure
//! path (missing/invalid X-API-Key → 401)".
//!
//! ## What this file actually exercises
//!
//! These tests stand up the full production server stack as a single tower
//! `Service` and drive it with `tower::ServiceExt::oneshot`. No real socket is
//! bound for the protected app — we route axum requests directly through the
//! same composition the binary will install when `--serve` mode lands:
//!
//! ```text
//!   protect_router(cc_http::build_router(state), ApiKeyAuth)
//!     → X-API-Key middleware (cli::serve_auth)
//!     → cc_http::ask_handler  (cc_http::handlers)
//!     → cc_query::run_query_loop  (cc-query agentic loop)
//!     → cc_api::AnthropicClient   (real reqwest over real TCP)
//!     → POST http://127.0.0.1:<port>/v1/messages
//!         (a fake upstream we bind in-process — see `spawn_fake_upstream`)
//! ```
//!
//! The fake upstream returns a canned SSE end-turn frame so the agentic loop
//! produces a deterministic answer. The real upstream (DeepSeek's
//! Anthropic-compatible endpoint) is never contacted from these tests.
//!
//! ## Why these are integration tests, not unit tests
//!
//!   * They link against the full `cc_http` + `cc_query` + `cc_api` stack as
//!     dependents — a unit test inside any one crate could not assert the
//!     auth-then-handler-then-loop wiring as a whole.
//!   * They drive the request through the same `protect_router(...)` call
//!     site the binary will use, so a future refactor that detaches the auth
//!     middleware from the bare router is caught here as a status-code
//!     regression.
//!   * The auth-failure assertions are intentionally **redundant** with the
//!     unit tests in `serve_auth.rs`. Belt-and-suspenders: the unit tests pin
//!     middleware behaviour, and these pin the production composition's
//!     behaviour. If somebody later swaps in a different auth layer, the unit
//!     tests would still pass — but the integration tests would catch the
//!     wire-level regression.

use std::sync::Arc;

use axum::{
    body::Body,
    extract::State,
    http::{header, Method, Request, StatusCode},
    response::IntoResponse,
    routing::post,
    Router,
};
use cc_core::{cost::CostTracker, permissions::AutoPermissionHandler};
use cc_http::{build_router, AskState};
use cc_query::QueryConfig;
use cc_tools::ToolContext;
use claude_code::serve_auth::{protect_router, ApiKeyAuth, API_KEY_HEADER};
use http_body_util::BodyExt;
use serde_json::json;
use tower::ServiceExt; // .oneshot

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// The shared secret these tests configure for the protected router. Picked
/// to be obviously a test value; avoid anything that looks like a credential
/// shape so a stray grep over the repo never confuses a reader.
const TEST_API_KEY: &str = "integration-test-secret";

// ---------------------------------------------------------------------------
// Fake upstream (mocks DeepSeek's Anthropic-compatible /v1/messages endpoint)
// ---------------------------------------------------------------------------

/// Build the SSE response body the fake upstream returns on every request.
///
/// The frames are formatted to match the format `cc_api::AnthropicClient`'s
/// `process_sse_stream` parses: `event:` + `data:` line pairs separated by
/// a blank line, JSON payloads matching the live Anthropic Messages API
/// streaming wire format. We emit exactly enough frames to drive the
/// `StreamAccumulator` in `cc-api` to a synthesized assistant message with
/// `stop_reason = "end_turn"`:
///
///   * `message_start`        — sets the model and zero-token usage
///   * `content_block_start`  — opens a single text content block at index 0
///   * `content_block_delta`  — pushes the entire `answer` text in one go
///   * `content_block_stop`   — closes the block
///   * `message_delta`        — emits `stop_reason: "end_turn"`
///   * `message_stop`         — terminates the stream
///
/// The handler wins by being deterministic: the agentic loop sees a single
/// non-tool-use turn and exits on `end_turn`, so the test's expected answer
/// equals the `answer` argument verbatim.
fn sse_body(answer: &str) -> String {
    let frames: [(&str, serde_json::Value); 6] = [
        (
            "message_start",
            json!({
                "type": "message_start",
                "message": {
                    "id": "msg_integration_test",
                    "type": "message",
                    "role": "assistant",
                    "model": "test-model",
                    "content": [],
                    "usage": { "input_tokens": 1, "output_tokens": 0 }
                }
            }),
        ),
        (
            "content_block_start",
            json!({
                "type": "content_block_start",
                "index": 0,
                "content_block": { "type": "text", "text": "" }
            }),
        ),
        (
            "content_block_delta",
            json!({
                "type": "content_block_delta",
                "index": 0,
                "delta": { "type": "text_delta", "text": answer }
            }),
        ),
        (
            "content_block_stop",
            json!({ "type": "content_block_stop", "index": 0 }),
        ),
        (
            "message_delta",
            json!({
                "type": "message_delta",
                "delta": { "stop_reason": "end_turn" },
                "usage": { "output_tokens": 7 }
            }),
        ),
        ("message_stop", json!({ "type": "message_stop" })),
    ];

    let mut out = String::new();
    for (event, data) in frames {
        // SSE frames: `event:` line, `data:` line, blank line terminator.
        // The `cc-api` SSE parser splits on blank lines, so the trailing
        // `\n\n` is required for each frame to be emitted as a discrete
        // event.
        out.push_str("event: ");
        out.push_str(event);
        out.push('\n');
        out.push_str("data: ");
        out.push_str(&data.to_string());
        out.push_str("\n\n");
    }
    out
}

/// Axum handler used by the fake upstream. Consumes (and ignores) the request
/// body so the connection isn't closed prematurely, then emits the canned
/// SSE response.
async fn fake_messages_handler(
    State(answer): State<Arc<String>>,
    _body: axum::body::Bytes,
) -> impl IntoResponse {
    let body = sse_body(&answer);
    (
        [(header::CONTENT_TYPE, "text/event-stream")],
        body,
    )
}

/// Bind a `127.0.0.1:0` listener and start serving a fake DeepSeek-compatible
/// `POST /v1/messages` endpoint that always responds with `answer` as the
/// final assistant text. Returns the `http://host:port` base URL the
/// `AnthropicClient` should be configured with.
///
/// The spawned axum task is intentionally leaked: it lives until the test
/// process tears down. Each test function builds its own listener so that
/// parallel test execution does not race on a shared port.
async fn spawn_fake_upstream(answer: &str) -> String {
    let answer = Arc::new(answer.to_string());
    let app = Router::new()
        .route("/v1/messages", post(fake_messages_handler))
        .with_state(answer);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind 127.0.0.1:0 for fake upstream");
    let addr = listener
        .local_addr()
        .expect("local_addr on bound listener");

    tokio::spawn(async move {
        // If the test finishes before this serve loop, the runtime aborts
        // the task on shutdown — that's fine.
        let _ = axum::serve(listener, app).await;
    });

    format!("http://{}", addr)
}

// ---------------------------------------------------------------------------
// Protected app builder
// ---------------------------------------------------------------------------

/// Construct the production-shape protected router for these tests:
/// `protect_router(cc_http::build_router(state), ApiKeyAuth::new(TEST_API_KEY))`.
///
/// `api_base` is wired into the `AnthropicClient` so the agentic loop talks to
/// our fake upstream instead of the real DeepSeek endpoint. For auth-failure
/// tests `api_base` is irrelevant (the middleware short-circuits before the
/// loop runs); we still pass a valid-shape URL so `AnthropicClient::new`
/// doesn't reject it.
fn build_protected_app(api_base: String) -> Router {
    let cfg = cc_core::config::Config::default();
    let tool_ctx = ToolContext {
        working_dir: std::path::PathBuf::from("."),
        permission_mode: cc_core::config::PermissionMode::Default,
        permission_handler: Arc::new(AutoPermissionHandler {
            mode: cc_core::config::PermissionMode::Default,
        }),
        cost_tracker: CostTracker::new(),
        session_id: "integration-test-session".to_string(),
        non_interactive: true,
        mcp_manager: None,
        config: cfg,
    };

    let client = Arc::new(
        cc_api::AnthropicClient::new(cc_api::client::ClientConfig {
            // Non-empty key required by `AnthropicClient::new`. The fake
            // upstream doesn't validate it; the real DeepSeek endpoint never
            // sees this value.
            api_key: "fake-deepseek-key".to_string(),
            api_base,
            // Trim retry budget so a hypothetical upstream failure surfaces
            // quickly instead of stretching the test runtime.
            max_retries: 0,
            ..Default::default()
        })
        .expect("AnthropicClient::new with non-empty api_key"),
    );

    // Cap turns at 1 — the fake upstream returns end_turn unconditionally,
    // and even one accidental extra round-trip would be a bug worth catching.
    let query_config = QueryConfig {
        model: "test-model".to_string(),
        max_tokens: 256,
        max_turns: 1,
        // Empty system prompt: keeps the request body small and deterministic.
        system_prompt: Some(String::new()),
        ..QueryConfig::default()
    };

    let state = AskState::new(client, tool_ctx, query_config, CostTracker::new());
    let auth = ApiKeyAuth::new(TEST_API_KEY).expect("ApiKeyAuth::new with non-empty key");
    protect_router(build_router(state), auth)
}

/// Build a `POST /ask` request body containing `question`.
fn ask_body(question: &str) -> Body {
    Body::from(serde_json::to_vec(&json!({ "question": question })).unwrap())
}

/// Drain `resp` into a `(status, body bytes)` pair. Most tests parse the body
/// as JSON afterwards, but the helper returns raw bytes so a failing
/// `assert_eq!` can still print whatever the handler actually emitted.
async fn collect_response(
    resp: axum::response::Response,
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let status = resp.status();
    let headers = resp.headers().clone();
    let bytes = resp
        .into_body()
        .collect()
        .await
        .expect("collect response body")
        .to_bytes();
    (status, headers, bytes.to_vec())
}

// ===========================================================================
// Auth-failure path: missing / invalid X-API-Key → 401 Unauthorized
// ===========================================================================

/// Missing `X-API-Key` header must short-circuit at the middleware with a
/// 401 response and the `WWW-Authenticate` hint AC 2 nailed in. The agentic
/// loop must NOT run — we wire `api_base` to a port nothing is listening on
/// so a misrouted request would deterministically time out instead of
/// silently succeeding.
#[tokio::test]
async fn auth_failure_missing_x_api_key_returns_401() {
    let app = build_protected_app("http://127.0.0.1:1".to_string());

    let req = Request::builder()
        .method(Method::POST)
        .uri("/ask")
        .header(header::CONTENT_TYPE, "application/json")
        .body(ask_body("any question — should not reach the handler"))
        .expect("build request");

    let resp = app.oneshot(req).await.expect("oneshot");
    let (status, headers, body) = collect_response(resp).await;

    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "missing X-API-Key must produce 401, got body: {}",
        String::from_utf8_lossy(&body),
    );

    // The `WWW-Authenticate` header hints at the expected scheme — pinned by
    // AC 2 so an auth refactor that loses it would be flagged here.
    let www_auth = headers
        .get(header::WWW_AUTHENTICATE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        www_auth.starts_with("ApiKey"),
        "401 must carry WWW-Authenticate: ApiKey..., got: {:?}",
        www_auth,
    );

    // The error envelope shape mirrors the rest of the handler's error
    // surface: `{ "error": "...", "message": "..." }`.
    let parsed: serde_json::Value =
        serde_json::from_slice(&body).expect("401 body must be JSON");
    assert_eq!(
        parsed.get("error").and_then(|v| v.as_str()),
        Some("unauthorized"),
        "401 envelope `error` field must be `unauthorized`, got: {parsed}",
    );
    assert!(
        parsed
            .get("message")
            .and_then(|v| v.as_str())
            .map(|m| m.contains("missing X-API-Key"))
            .unwrap_or(false),
        "401 envelope must mention `missing X-API-Key`, got: {parsed}",
    );
}

/// Header present but value mismatched must also produce 401. Distinct from
/// the missing-header case so a future refactor that conflates the two error
/// paths is caught.
#[tokio::test]
async fn auth_failure_wrong_x_api_key_returns_401() {
    let app = build_protected_app("http://127.0.0.1:1".to_string());

    let req = Request::builder()
        .method(Method::POST)
        .uri("/ask")
        .header(API_KEY_HEADER, "definitely-not-the-secret")
        .header(header::CONTENT_TYPE, "application/json")
        .body(ask_body("payload that should never reach the handler"))
        .expect("build request");

    let resp = app.oneshot(req).await.expect("oneshot");
    let (status, headers, body) = collect_response(resp).await;

    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "wrong X-API-Key must produce 401, got body: {}",
        String::from_utf8_lossy(&body),
    );

    assert!(
        headers.contains_key(header::WWW_AUTHENTICATE),
        "401 must carry WWW-Authenticate header"
    );

    let parsed: serde_json::Value =
        serde_json::from_slice(&body).expect("401 body must be JSON");
    assert_eq!(
        parsed.get("error").and_then(|v| v.as_str()),
        Some("unauthorized"),
    );
    assert!(
        parsed
            .get("message")
            .and_then(|v| v.as_str())
            .map(|m| m.contains("invalid X-API-Key"))
            .unwrap_or(false),
        "401 envelope must mention `invalid X-API-Key`, got: {parsed}",
    );
}

/// Empty header value (header present but `""`) must still 401 — guards
/// against any accidental "null-key bypass" where an empty `X-API-Key`
/// matches an empty configured key. (`ApiKeyAuth::new("")` would fail at
/// startup, so this is defence-in-depth.)
#[tokio::test]
async fn auth_failure_empty_x_api_key_returns_401() {
    let app = build_protected_app("http://127.0.0.1:1".to_string());

    let req = Request::builder()
        .method(Method::POST)
        .uri("/ask")
        .header(API_KEY_HEADER, "")
        .header(header::CONTENT_TYPE, "application/json")
        .body(ask_body("ignored"))
        .expect("build request");

    let resp = app.oneshot(req).await.expect("oneshot");
    let (status, _, _) = collect_response(resp).await;

    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// Happy path: valid key + question → 200 with `{ "answer": "..." }`
// ===========================================================================

/// End-to-end happy-path: a request with a valid `X-API-Key` and a non-empty
/// `question` reaches the agentic loop, the loop talks to the fake upstream,
/// and the response is the canonical `{ "answer": "..." }` JSON.
///
/// Because the fake upstream emits exactly one assistant text block with
/// `stop_reason = "end_turn"` and no tool-use blocks, the answer the handler
/// returns is the verbatim text the upstream streamed.
#[tokio::test]
async fn happy_path_valid_key_and_question_returns_200_with_answer_json() {
    const ANSWER: &str = "42 is the answer.";

    let api_base = spawn_fake_upstream(ANSWER).await;
    let app = build_protected_app(api_base);

    let req = Request::builder()
        .method(Method::POST)
        .uri("/ask")
        .header(API_KEY_HEADER, TEST_API_KEY)
        .header(header::CONTENT_TYPE, "application/json")
        .body(ask_body("what is the answer?"))
        .expect("build request");

    let resp = app.oneshot(req).await.expect("oneshot");
    let (status, headers, body) = collect_response(resp).await;

    assert_eq!(
        status,
        StatusCode::OK,
        "expected 200 OK, got {} with body: {}",
        status,
        String::from_utf8_lossy(&body),
    );

    // Response shape lock: must be `application/json` per the seed contract.
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        content_type.starts_with("application/json"),
        "expected application/json content-type, got: {content_type:?}",
    );

    // The body must deserialize as `{ "answer": <ANSWER> }` and contain
    // exactly that one wire field. No token counts, no tool traces, no
    // model id, no cost — locked by the seed contract.
    let parsed: serde_json::Value =
        serde_json::from_slice(&body).expect("200 body must be JSON");
    let obj = parsed
        .as_object()
        .expect("200 body must be a JSON object");

    assert_eq!(
        obj.len(),
        1,
        "200 body must have exactly one wire field (answer), got: {:?}",
        obj.keys().collect::<Vec<_>>(),
    );
    assert_eq!(
        obj.get("answer").and_then(|v| v.as_str()),
        Some(ANSWER),
        "expected `answer` field == `{ANSWER}`, full body: {parsed}",
    );
}

/// A second happy-path variant exercising a multi-byte / non-ASCII answer
/// to ensure the SSE pipe round-trips Unicode untouched. The agentic loop
/// concatenates text deltas as bytes, so a UTF-8 boundary mishandling in
/// the SSE parser, the handler, or the JSON serializer would surface as a
/// mangled answer string here.
#[tokio::test]
async fn happy_path_unicode_answer_round_trips() {
    const ANSWER: &str = "答え：42 ✓";

    let api_base = spawn_fake_upstream(ANSWER).await;
    let app = build_protected_app(api_base);

    let req = Request::builder()
        .method(Method::POST)
        .uri("/ask")
        .header(API_KEY_HEADER, TEST_API_KEY)
        .header(header::CONTENT_TYPE, "application/json")
        .body(ask_body("answer in any language"))
        .expect("build request");

    let resp = app.oneshot(req).await.expect("oneshot");
    let (status, _, body) = collect_response(resp).await;

    assert_eq!(status, StatusCode::OK);
    let parsed: serde_json::Value =
        serde_json::from_slice(&body).expect("body must be JSON");
    assert_eq!(
        parsed.get("answer").and_then(|v| v.as_str()),
        Some(ANSWER),
    );
}
