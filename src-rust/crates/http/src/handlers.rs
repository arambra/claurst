//! Axum request handlers for the `cc-http` crate.
//!
//! This module hosts the production [`ask_handler`] for `POST /ask` — the
//! synchronous, single-turn REST endpoint that drives the `cc-query` agentic
//! loop with a restricted, read-only tool subset.
//!
//! ## What this handler does
//!
//! For each authenticated request (auth is enforced upstream of this module by
//! `serve_auth.rs`'s X-API-Key middleware — see the AC 2 work):
//!
//!   1. **Validate the inbound body**. The `question` field is trimmed and
//!      rejected with 400 Bad Request if empty / whitespace-only.
//!   2. **Seed the conversation** with exactly one user-turn message containing
//!      the trimmed question. No prior history is stitched in — `/ask` is
//!      stateless and per-request.
//!   3. **Invoke the agentic loop** via [`cc_query::run_query_loop`] using the
//!      restricted tool registry from [`crate::restricted_tools`]
//!      (`web_fetch`, `todo`). The loop iterates internally to drive any tool
//!      calls the model emits, but `QueryConfig::max_turns` caps the total
//!      number of model invocations so a runaway tool-use cycle cannot exceed
//!      the per-request budget. Single-turn-from-the-user-perspective is
//!      enforced by the message vector seed (one user turn) plus the turn cap.
//!   4. **Map the outcome** back to an HTTP response. Successful end-turn
//!      answers become `200 OK` with `{ "answer": "..." }`. Loop errors map to
//!      the AC 3 status contract:
//!
//!         * non-rate-limit upstream → `502 Bad Gateway`
//!         * `RateLimit` / `ApiStatus { 429 | 529 }` → `503 Service Unavailable`
//!         * `ContextWindowExceeded` → `413 Payload Too Large`
//!         * `Cancelled` → `504 Gateway Timeout`
//!         * everything else → `500 Internal Server Error`
//!
//! The handler **never** surfaces token counts, tool-invocation traces, model
//! identifiers, or any other structured metadata in the response body — the
//! seed contract is explicit on that point. Those values are logged for
//! operator visibility, never exposed to clients.
//!
//! ## Boundary contract (must not regress)
//!
//!   * Response wire shape stays exactly `{ "answer": "..." }` on success and
//!     `{ "error": "...", "message": "..." }` on failure.
//!   * Auth is enforced upstream (`serve_auth.rs`); this handler reads no
//!     credentials of its own.
//!   * Error-status mapping mirrors AC 3 exactly — non-rate-limit upstream →
//!     502, rate-limit / 429 / 529 → 503, `ContextWindowExceeded` → 413.
//!   * No write/execute tools are ever invoked — guarded by the
//!     [`crate::restricted_tools`] registry, which AC 2's tool-list tests pin
//!     to exactly `WebFetch` + `TodoWrite`.

use std::sync::Arc;

use axum::{extract::State, http::StatusCode, Json};
use cc_core::cost::CostTracker;
use cc_core::error::ClaudeError;
use cc_core::types::{ContentBlock, Message, MessageContent};
use cc_query::{QueryConfig, QueryOutcome};
use cc_tools::{Tool, ToolContext};
use serde::Serialize;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};

use crate::types::{AskRequest, AskResponse};

// ---------------------------------------------------------------------------
// Handler state
// ---------------------------------------------------------------------------

/// Shared state injected into [`ask_handler`] by axum on every request.
///
/// All fields are cheap to clone:
///   * `client` and `tools` are wrapped in `Arc`,
///   * `tool_ctx` is `#[derive(Clone)]` and holds `Arc`-backed sub-fields,
///   * `query_config` is plain `Clone`,
///   * `cost_tracker` is `Arc<CostTracker>`.
///
/// The handler reads from this state but never mutates it, so there is no
/// inner lock — concurrency under the configured single-replica deployment
/// is bounded by the request count, not by lock contention.
///
/// The canonical builder is [`AskState::new`], which wraps
/// [`crate::restricted_tools`] for the tool registry. Tests that need to
/// substitute a mocked tool can construct `AskState` field-by-field.
#[derive(Clone)]
pub struct AskState {
    /// Anthropic-compatible HTTP client (talks to DeepSeek in production).
    pub client: Arc<cc_api::AnthropicClient>,
    /// Restricted tool registry — should be the output of
    /// [`crate::restricted_tools`]. Inner items are `Arc<dyn Tool>` so the
    /// registry can be shared with the cc-query loop without re-instantiating
    /// tools per request; the outer `Arc<Vec<...>>` keeps the whole list a
    /// cheap-clone for axum state.
    pub tools: Arc<Vec<Arc<dyn Tool>>>,
    /// Tool execution context (working dir, permissions, cost tracker, …).
    pub tool_ctx: ToolContext,
    /// Query loop configuration: model, max_tokens, max_turns, system prompt.
    pub query_config: QueryConfig,
    /// Token-usage accumulator. Tracked internally; never returned to clients
    /// (the seed contract forbids structured response metadata).
    pub cost_tracker: Arc<CostTracker>,
}

impl AskState {
    /// Construct an `AskState` with [`crate::restricted_tools`] already plugged
    /// in.
    ///
    /// This is the canonical builder for production use. Callers that need to
    /// supply their own tool list (e.g. tests using a mocked tool) should
    /// construct `AskState` field-by-field.
    pub fn new(
        client: Arc<cc_api::AnthropicClient>,
        tool_ctx: ToolContext,
        query_config: QueryConfig,
        cost_tracker: Arc<CostTracker>,
    ) -> Self {
        Self {
            client,
            tools: Arc::new(crate::restricted_tools()),
            tool_ctx,
            query_config,
            cost_tracker,
        }
    }
}

// ---------------------------------------------------------------------------
// Error envelope
// ---------------------------------------------------------------------------

/// Error envelope returned on every non-2xx exit from [`ask_handler`].
///
/// Mirrors the JSON shape used by the auth middleware
/// (`crates/cli/src/serve_auth.rs`) so clients see a uniform
/// `{ "error": "...", "message": "..." }` body across 401s and 4xx/5xx
/// responses from the handler.
///
/// `Serialize` only (deliberately not `Deserialize`): this is a server-side
/// response shape, and clients are free to parse it any way they like.
#[derive(Debug, Clone, Serialize)]
pub struct AskErrorResponse {
    /// Stable, machine-readable error category.
    pub error: String,
    /// Human-readable detail describing the failure.
    pub message: String,
}

impl AskErrorResponse {
    fn new(error: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            error: error.into(),
            message: message.into(),
        }
    }
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/// `POST /ask` — synchronous, single-turn agentic-loop endpoint.
///
/// Runs the user's question through [`cc_query::run_query_loop`] against the
/// restricted tool registry and returns the final answer as JSON. The handler
/// blocks until the loop reaches `end_turn` (or hits an error / max_turns /
/// max_tokens), so axum's per-request timeout ultimately bounds wall-clock
/// duration. In production the Container Apps ingress timeout is 240s; an
/// upstream tower-http `TimeoutLayer` should mirror that limit.
///
/// On success: `200 OK` with `{ "answer": "..." }`.
///
/// On failure:
///   * `400 Bad Request`  — empty / whitespace-only question.
///   * `502 Bad Gateway`  — upstream model-service failure (AC 3 contract).
///   * `503 Service Unavailable` — rate-limited / overloaded upstream.
///   * `413 Payload Too Large` — context window exceeded.
///   * `504 Gateway Timeout` — agentic loop cancelled before completion.
///   * `500 Internal Server Error` — anything else.
///
/// The handler:
///   * never invokes a write or execute tool (enforced by
///     [`crate::restricted_tools`]),
///   * never echoes the X-API-Key (auth is enforced upstream by middleware),
///   * never returns token counts or tool traces (forbidden by the seed
///     contract — minimal public attack surface).
pub async fn ask_handler(
    State(state): State<AskState>,
    Json(req): Json<AskRequest>,
) -> Result<Json<AskResponse>, (StatusCode, Json<AskErrorResponse>)> {
    let question = validate_question(&req.question)?;

    // Log the length, NOT the content. The question may carry PII or
    // operational secrets the operator does not want in logs.
    info!(
        question_len = question.len(),
        tool_count = state.tools.len(),
        max_turns = state.query_config.max_turns,
        "/ask request received"
    );

    // Single-turn input: a fresh conversation containing exactly the user's
    // question. The agentic loop may extend this with tool-use / tool-result
    // round trips internally, but no prior history is stitched in. The
    // `max_turns` cap on the QueryConfig bounds how many internal model
    // invocations the loop is allowed before forcibly returning, so a
    // runaway tool-use cycle cannot blow past the per-request budget.
    let mut messages: Vec<Message> = vec![Message::user(question)];

    // No external cancellation source for now — axum drops the future when
    // the client disconnects, which propagates as the handler future being
    // dropped, but the inner loop's own cancel token is independent. A
    // never-cancelled token is fine: outer middleware (timeout layer) is
    // responsible for bounding total duration.
    let cancel_token = CancellationToken::new();

    // Drive the agentic loop to completion. We pass `None` for the event
    // channel because this endpoint is synchronous: there is no SSE stream,
    // no progress consumer, and emitting events nobody reads would just
    // queue them in memory until the channel is dropped.
    let outcome = cc_query::run_query_loop(
        state.client.as_ref(),
        &mut messages,
        state.tools.as_slice(),
        &state.tool_ctx,
        &state.query_config,
        state.cost_tracker.clone(),
        None,
        cancel_token,
    )
    .await;

    match outcome {
        QueryOutcome::EndTurn { message, usage } => {
            let tool_uses_in_final = count_tool_uses(&message);
            let answer = message.get_all_text();
            // Telemetry only — token counts and tool-use counts are NOT
            // surfaced in the response body (seed contract: "no structured
            // response metadata"). Logging them gives operators visibility
            // without exposing them to clients.
            info!(
                answer_len = answer.len(),
                tool_uses_in_final_message = tool_uses_in_final,
                input_tokens = usage.input_tokens,
                output_tokens = usage.output_tokens,
                "/ask handler returning end_turn answer"
            );
            if answer.is_empty() {
                // The model ended its turn without emitting any text — this
                // is degenerate but legal (e.g. it emitted only a tool_use
                // block as its last message and the loop terminated). Return
                // 502 so callers know the upstream model produced nothing
                // useful, rather than a confusing empty 200.
                warn!("/ask end_turn produced an empty assistant message");
                return Err((
                    StatusCode::BAD_GATEWAY,
                    Json(AskErrorResponse::new(
                        "empty_answer",
                        "the agentic loop completed without producing any answer text",
                    )),
                ));
            }
            debug!("/ask returning {}-byte answer", answer.len());
            Ok(Json(AskResponse { answer }))
        }
        QueryOutcome::MaxTokens { partial_message, usage } => {
            // The model was cut off mid-response. Hand back whatever text it
            // managed to emit — clients are free to retry with a higher
            // `max_tokens`. We log a warning but treat this as a successful
            // 200 because partial output is more useful than a 500 here.
            let answer = partial_message.get_all_text();
            warn!(
                answer_len = answer.len(),
                input_tokens = usage.input_tokens,
                output_tokens = usage.output_tokens,
                "/ask hit max_tokens — returning partial answer"
            );
            if answer.is_empty() {
                // No text at all even after a max_tokens cutoff — degrade to
                // 502 rather than returning an empty 200 that clients would
                // misinterpret as success.
                return Err((
                    StatusCode::BAD_GATEWAY,
                    Json(AskErrorResponse::new(
                        "empty_answer",
                        "max_tokens reached before any answer text was produced",
                    )),
                ));
            }
            Ok(Json(AskResponse { answer }))
        }
        QueryOutcome::Cancelled => {
            // Cancellation under this handler is most plausibly the
            // wrapping timeout layer aborting the loop because we ran past
            // the ingress deadline. 504 Gateway Timeout makes that explicit
            // to the caller; pure client-disconnect cancellations never see
            // a response body anyway.
            warn!("/ask agentic loop was cancelled before completion");
            Err((
                StatusCode::GATEWAY_TIMEOUT,
                Json(AskErrorResponse::new(
                    "request_cancelled",
                    "request was cancelled before the agentic loop completed",
                )),
            ))
        }
        QueryOutcome::Error(e) => {
            let status = claude_error_to_status(&e);
            let category = claude_error_category(&e);
            // Log the full error chain at error level so operators can
            // diagnose; only the short stringified form is returned to the
            // client (no upstream stack traces).
            error!(
                error = %e,
                status = %status.as_u16(),
                category = %category,
                "/ask agentic loop failed"
            );
            Err((
                status,
                Json(AskErrorResponse::new(category, e.to_string())),
            ))
        }
    }
}

// ---------------------------------------------------------------------------
// Validation & helper functions
// ---------------------------------------------------------------------------

/// Validate and normalise the inbound `question` string.
///
/// Returns the trimmed, non-empty question on success, or a
/// `(StatusCode, Json<AskErrorResponse>)` pair on failure. Pulled out of
/// [`ask_handler`] so the validation logic can be unit-tested without
/// constructing an axum `Json` extractor or a real `AskState`.
fn validate_question(
    raw: &str,
) -> Result<String, (StatusCode, Json<AskErrorResponse>)> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        warn!("/ask received an empty / whitespace-only question");
        return Err((
            StatusCode::BAD_REQUEST,
            Json(AskErrorResponse::new(
                "bad_request",
                "`question` field must be a non-empty string",
            )),
        ));
    }
    Ok(trimmed.to_string())
}

/// Count tool-use blocks recorded in an assistant message. Used purely for
/// observability — the count is logged, never returned in the response body
/// (the seed contract forbids structured response metadata).
fn count_tool_uses(message: &Message) -> usize {
    match &message.content {
        MessageContent::Text(_) => 0,
        MessageContent::Blocks(blocks) => blocks
            .iter()
            .filter(|b| matches!(b, ContentBlock::ToolUse { .. }))
            .count(),
    }
}

/// Map a `ClaudeError` from the agentic loop to a public HTTP status code.
///
/// The mapping is intentionally conservative: 4xx is reserved for genuine
/// client mistakes (the inbound request is malformed), so most loop errors —
/// even rate-limit hits — surface as 5xx. We do **not** propagate upstream
/// HTTP status codes verbatim, because:
///   * a 401/403 from DeepSeek would be misleading (the X-API-Key the *client*
///     sent us was valid; the upstream credential is what failed);
///   * leaking 4xx codes to clients invites probing of the upstream endpoint.
///
/// Status code rationale:
///   * `Auth(_)`        → 502: upstream refused our DEEPSEEK_API_KEY.
///   * `Api`/`ApiStatus`/`Http`/`Json` → 502: upstream service failure.
///   * `RateLimit` /  `ApiStatus { 429 | 529, .. }` → 503: shed load, retry-able.
///   * `ContextWindowExceeded`     → 413: client sent more than we can carry.
///   * `MaxTokensReached`          → 500: should have surfaced as
///     `QueryOutcome::MaxTokens`; if it bubbles out as Error, treat as a bug.
///   * `Cancelled`                 → 504: most realistic source under the
///     production timeout layer is a 240s ingress cutoff.
///   * `PermissionDenied`/`Tool`/`Io`/`Config`/`Mcp`/`Other` → 500:
///     internal server problem (and a misconfiguration in our deployment if
///     a Permission/Tool/MCP error reaches a /ask response at all).
fn claude_error_to_status(err: &ClaudeError) -> StatusCode {
    match err {
        // Upstream-side problems — the model service refused or failed.
        ClaudeError::Api(_)
        | ClaudeError::Auth(_)
        | ClaudeError::Http(_)
        | ClaudeError::Json(_) => StatusCode::BAD_GATEWAY,
        ClaudeError::ApiStatus { status, .. } => match *status {
            // Rate-limit / overloaded → 503 so callers know to back off.
            429 | 529 => StatusCode::SERVICE_UNAVAILABLE,
            // Anything else from upstream is a generic bad-gateway.
            _ => StatusCode::BAD_GATEWAY,
        },
        ClaudeError::RateLimit => StatusCode::SERVICE_UNAVAILABLE,

        // Request-shape problem — the question caused the conversation to
        // exceed the model's context window. 413 is the canonical
        // "client sent too much" code.
        ClaudeError::ContextWindowExceeded => StatusCode::PAYLOAD_TOO_LARGE,

        // Cancellation usually means the wrapping timeout layer aborted us
        // because the loop ran past the ingress deadline.
        ClaudeError::Cancelled => StatusCode::GATEWAY_TIMEOUT,

        // Everything else is an internal server problem. PermissionDenied,
        // Tool errors, MCP, and Io should not reach a /ask response with the
        // current restricted-tool registry — if they do, that's a deployment
        // bug, not a client error.
        ClaudeError::MaxTokensReached
        | ClaudeError::PermissionDenied(_)
        | ClaudeError::Tool(_)
        | ClaudeError::Io(_)
        | ClaudeError::Config(_)
        | ClaudeError::Mcp(_)
        | ClaudeError::Other(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

/// Stable machine-readable identifier for the error category. Keeps the JSON
/// `error` field consistent regardless of the human-readable wording — useful
/// for clients that want to handle specific categories without parsing
/// `message` strings.
fn claude_error_category(err: &ClaudeError) -> &'static str {
    match err {
        ClaudeError::Api(_) | ClaudeError::ApiStatus { .. } => "upstream_api_error",
        ClaudeError::Auth(_) => "upstream_auth_error",
        ClaudeError::Http(_) => "upstream_network_error",
        ClaudeError::Json(_) => "upstream_protocol_error",
        ClaudeError::RateLimit => "rate_limited",
        ClaudeError::ContextWindowExceeded => "context_window_exceeded",
        ClaudeError::MaxTokensReached => "max_tokens_reached",
        ClaudeError::Cancelled => "request_cancelled",
        ClaudeError::PermissionDenied(_) => "permission_denied",
        ClaudeError::Tool(_) => "tool_error",
        ClaudeError::Io(_) => "io_error",
        ClaudeError::Config(_) => "config_error",
        ClaudeError::Mcp(_) => "mcp_error",
        ClaudeError::Other(_) => "internal_error",
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -------- validate_question pure-function tests --------

    #[test]
    fn validate_question_accepts_canonical_input() {
        let q = validate_question("what is rust?").unwrap();
        assert_eq!(q, "what is rust?");
    }

    #[test]
    fn validate_question_trims_surrounding_whitespace() {
        let q = validate_question("  hello  ").unwrap();
        assert_eq!(q, "hello");
    }

    #[test]
    fn validate_question_preserves_internal_whitespace() {
        // Multi-line questions must round-trip — only outer whitespace
        // is trimmed. Internal newlines and double spaces stay.
        let q = validate_question("line one\n\nline two").unwrap();
        assert_eq!(q, "line one\n\nline two");
    }

    #[test]
    fn validate_question_rejects_empty() {
        let err = validate_question("").unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert_eq!(err.1.error, "bad_request");
    }

    #[test]
    fn validate_question_rejects_whitespace_only() {
        // Tabs, spaces, newlines — all whitespace, all rejected.
        let err = validate_question("   \n\t  ").unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert_eq!(err.1.error, "bad_request");
    }

    // -------- AskErrorResponse wire shape --------

    #[test]
    fn ask_error_response_serializes_canonically() {
        let body = AskErrorResponse::new("bad_request", "no question");
        let json = serde_json::to_value(&body).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "error": "bad_request",
                "message": "no question",
            })
        );
    }

    // -------- count_tool_uses --------

    #[test]
    fn count_tool_uses_zero_for_plain_text_message() {
        let m = Message::assistant("just text");
        assert_eq!(count_tool_uses(&m), 0);
    }

    #[test]
    fn count_tool_uses_zero_for_text_block_only() {
        let m = Message::assistant_blocks(vec![ContentBlock::Text {
            text: "answer".to_string(),
        }]);
        assert_eq!(count_tool_uses(&m), 0);
    }

    #[test]
    fn count_tool_uses_counts_each_tool_use_block() {
        let m = Message::assistant_blocks(vec![
            ContentBlock::Text {
                text: "I'll look this up".to_string(),
            },
            ContentBlock::ToolUse {
                id: "tu_1".to_string(),
                name: "WebFetch".to_string(),
                input: serde_json::json!({}),
            },
            ContentBlock::ToolUse {
                id: "tu_2".to_string(),
                name: "TodoWrite".to_string(),
                input: serde_json::json!({}),
            },
        ]);
        assert_eq!(count_tool_uses(&m), 2);
    }

    // -------- claude_error_to_status (AC 3 status contract) --------

    #[test]
    fn upstream_api_errors_map_to_502() {
        assert_eq!(
            claude_error_to_status(&ClaudeError::Api("upstream blew up".into())),
            StatusCode::BAD_GATEWAY
        );
        assert_eq!(
            claude_error_to_status(&ClaudeError::Auth("bad upstream key".into())),
            StatusCode::BAD_GATEWAY
        );
        // ApiStatus 5xx (other than overloaded) → 502.
        assert_eq!(
            claude_error_to_status(&ClaudeError::ApiStatus {
                status: 500,
                message: "boom".into(),
            }),
            StatusCode::BAD_GATEWAY
        );
        // ApiStatus 4xx → still 502 (we don't propagate upstream client codes).
        assert_eq!(
            claude_error_to_status(&ClaudeError::ApiStatus {
                status: 400,
                message: "malformed".into(),
            }),
            StatusCode::BAD_GATEWAY
        );
    }

    #[test]
    fn rate_limit_and_overloaded_map_to_503() {
        assert_eq!(
            claude_error_to_status(&ClaudeError::RateLimit),
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert_eq!(
            claude_error_to_status(&ClaudeError::ApiStatus {
                status: 429,
                message: "slow down".into(),
            }),
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert_eq!(
            claude_error_to_status(&ClaudeError::ApiStatus {
                status: 529,
                message: "overloaded".into(),
            }),
            StatusCode::SERVICE_UNAVAILABLE
        );
    }

    #[test]
    fn context_window_exceeded_maps_to_413() {
        assert_eq!(
            claude_error_to_status(&ClaudeError::ContextWindowExceeded),
            StatusCode::PAYLOAD_TOO_LARGE
        );
    }

    #[test]
    fn cancelled_loop_error_maps_to_504() {
        assert_eq!(
            claude_error_to_status(&ClaudeError::Cancelled),
            StatusCode::GATEWAY_TIMEOUT
        );
    }

    #[test]
    fn internal_errors_map_to_500() {
        for err in [
            ClaudeError::PermissionDenied("nope".into()),
            ClaudeError::Tool("broke".into()),
            ClaudeError::Config("bad".into()),
            ClaudeError::Mcp("offline".into()),
            ClaudeError::Other("?".into()),
            ClaudeError::MaxTokensReached,
        ] {
            assert_eq!(
                claude_error_to_status(&err),
                StatusCode::INTERNAL_SERVER_ERROR,
                "Expected 500 for {:?}",
                err
            );
        }
    }

    /// `claude_error_to_status` must never return a code that would imply the
    /// inbound request itself was malformed (e.g. 401, 403, 404). The auth
    /// middleware owns 401 territory, and 4xx reuse here would either confuse
    /// API-key clients or invite probing of upstream endpoints.
    #[test]
    fn claude_error_status_never_uses_4xx_except_413() {
        let cases = [
            ClaudeError::Api("x".into()),
            ClaudeError::Auth("x".into()),
            ClaudeError::PermissionDenied("x".into()),
            ClaudeError::Tool("x".into()),
            ClaudeError::Config("x".into()),
            ClaudeError::Mcp("x".into()),
            ClaudeError::Other("x".into()),
            ClaudeError::RateLimit,
            ClaudeError::ContextWindowExceeded,
            ClaudeError::MaxTokensReached,
            ClaudeError::Cancelled,
            ClaudeError::ApiStatus {
                status: 401,
                message: "upstream rejected".into(),
            },
            ClaudeError::ApiStatus {
                status: 403,
                message: "upstream forbidden".into(),
            },
            ClaudeError::ApiStatus {
                status: 404,
                message: "upstream not found".into(),
            },
            ClaudeError::ApiStatus {
                status: 429,
                message: "upstream rate".into(),
            },
        ];
        for case in &cases {
            let status = claude_error_to_status(case);
            // 413 is the one legitimate 4xx exit (request size).
            if status == StatusCode::PAYLOAD_TOO_LARGE {
                continue;
            }
            assert!(
                status.is_server_error(),
                "Loop error {:?} produced non-server status {}",
                case,
                status
            );
        }
    }

    // -------- claude_error_category --------

    #[test]
    fn claude_error_category_uses_stable_machine_keys() {
        // Lock the wire-format strings so clients can switch on them.
        assert_eq!(
            claude_error_category(&ClaudeError::Api("x".into())),
            "upstream_api_error"
        );
        assert_eq!(
            claude_error_category(&ClaudeError::Auth("x".into())),
            "upstream_auth_error"
        );
        assert_eq!(
            claude_error_category(&ClaudeError::RateLimit),
            "rate_limited"
        );
        assert_eq!(
            claude_error_category(&ClaudeError::ContextWindowExceeded),
            "context_window_exceeded"
        );
        assert_eq!(
            claude_error_category(&ClaudeError::Cancelled),
            "request_cancelled"
        );
        assert_eq!(
            claude_error_category(&ClaudeError::Tool("x".into())),
            "tool_error"
        );
    }

    // -------- AskState construction sanity --------

    /// Smoke test: `AskState::new` plugs in `restricted_tools()` and produces
    /// a clone-safe state. We don't drive an end-to-end request here because
    /// that requires a live `AnthropicClient` against a real DeepSeek
    /// backend; round-trip behaviour is covered separately by the
    /// integration tests under `crates/cli`.
    #[test]
    fn ask_state_new_uses_restricted_tools() {
        // Build a minimal `ToolContext` and `CostTracker` with the smallest
        // permission/config surface that compiles.
        let cfg = cc_core::config::Config::default();
        let tool_ctx = ToolContext {
            working_dir: std::path::PathBuf::from("."),
            permission_mode: cc_core::config::PermissionMode::Default,
            permission_handler: Arc::new(cc_core::permissions::AutoPermissionHandler {
                mode: cc_core::config::PermissionMode::Default,
            }),
            cost_tracker: CostTracker::new(),
            session_id: "test-session".to_string(),
            non_interactive: true,
            mcp_manager: None,
            config: cfg,
        };
        let query_config = QueryConfig::default();
        let cost_tracker = CostTracker::new();

        // We need a real AnthropicClient to satisfy the type, but we never
        // call into it because we only assert on the tool registry shape.
        // Use a placeholder API key — `AnthropicClient::new` only validates
        // non-empty.
        let client = Arc::new(
            cc_api::AnthropicClient::new(cc_api::client::ClientConfig {
                api_key: "dummy".to_string(),
                ..Default::default()
            })
            .expect("AnthropicClient must construct with non-empty api_key"),
        );

        let state = AskState::new(client, tool_ctx, query_config, cost_tracker);
        assert_eq!(
            state.tools.len(),
            2,
            "AskState::new must wire restricted_tools(): exactly 2 tools"
        );
        let names: std::collections::HashSet<&str> =
            state.tools.iter().map(|t| t.name()).collect();
        assert!(
            names.contains(cc_core::constants::TOOL_NAME_WEB_FETCH),
            "AskState must include WebFetch"
        );
        assert!(
            names.contains(cc_core::constants::TOOL_NAME_TODO_WRITE),
            "AskState must include TodoWrite"
        );
    }

    /// `AskState` must be cheap to clone — every field is `Arc`-backed or
    /// trivially `Clone`. axum extracts state by cloning per-request, so any
    /// future field that is not `Clone` would silently break compilation
    /// when `State<AskState>` is used in a handler signature.
    #[test]
    fn ask_state_is_clone() {
        fn assert_clone<T: Clone>(_t: &T) {}
        let cfg = cc_core::config::Config::default();
        let tool_ctx = ToolContext {
            working_dir: std::path::PathBuf::from("."),
            permission_mode: cc_core::config::PermissionMode::Default,
            permission_handler: Arc::new(cc_core::permissions::AutoPermissionHandler {
                mode: cc_core::config::PermissionMode::Default,
            }),
            cost_tracker: CostTracker::new(),
            session_id: "test-session".to_string(),
            non_interactive: true,
            mcp_manager: None,
            config: cfg,
        };
        let client = Arc::new(
            cc_api::AnthropicClient::new(cc_api::client::ClientConfig {
                api_key: "dummy".to_string(),
                ..Default::default()
            })
            .unwrap(),
        );
        let state = AskState::new(
            client,
            tool_ctx,
            QueryConfig::default(),
            CostTracker::new(),
        );
        assert_clone(&state);
    }
}
