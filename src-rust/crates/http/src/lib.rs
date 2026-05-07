//! `cc-http` — HTTP server for the claurst REST surface.
//!
//! This crate is the home of the synchronous `POST /ask` endpoint that runs
//! a single user-turn through the `cc-query` agentic loop with a restricted,
//! read-only tool subset (`web_fetch`, `todo`, plus pure LLM reasoning).
//!
//! The crate is deliberately a library rather than a binary: the
//! `claude-code` CLI binary (in `crates/cli`) opts in to server mode via a
//! flag/subcommand and calls into this library, which keeps the handler,
//! router, and middleware unit-testable without spinning up a real process.
//!
//! ## Public surface
//!
//!   * [`build_router`] — constructs the bare axum [`Router`] that registers
//!     the `POST /ask` route, with [`handlers::AskState`] supplied by the
//!     caller. Returned without any auth middleware so that callers (currently
//!     `crates/cli`) can layer their own X-API-Key gate on top via
//!     [`Router::route_layer`] before serving traffic.
//!   * [`with_request_timeout`] / [`request_timeout_layer`] /
//!     [`REQUEST_TIMEOUT`] — application-side enforcement of the
//!     240-second per-request deadline that mirrors the Azure Container Apps
//!     ingress idle timeout. Callers compose the timeout layer over the bare
//!     router (typically *outermost*, so it bounds even the auth-middleware
//!     phase) and the agentic loop is cut off before the platform-level
//!     deadline can return an opaque 504 to the client.
//!   * [`with_request_logging`] — outermost access-log layer that emits a
//!     structured `info!` event on request start (method, URI, declared
//!     Content-Length) and another on response (status, latency). Apply on
//!     top of every other layer so it captures requests rejected by inner
//!     layers (timeouts, auth failures, extractor errors) as well as
//!     successful handler invocations. Bodies and headers other than
//!     `Content-Length` are deliberately not logged.
//!   * [`serve`] — convenience entry point: binds a [`TcpListener`] to the
//!     supplied [`SocketAddr`] and serves [`build_router`] on it, wrapped in
//!     [`with_request_timeout`] and [`with_request_logging`] so the
//!     240-second cap and access log are applied even when callers don't
//!     compose extra middleware. Suitable for tests / dev / any deployment
//!     that wires auth in some other way (for instance, in front of the
//!     process at the ingress layer).
//!   * [`handlers::ask_handler`] / [`handlers::AskState`] /
//!     [`AskErrorResponse`] — the handler the router dispatches to, the state
//!     it closes over, and the JSON error envelope it returns on non-2xx
//!     exits.
//!   * [`AskRequest`] / [`AskResponse`] — the locked-in JSON wire types for
//!     the `/ask` endpoint.
//!   * [`restricted_tools`] — the read-only tool registry the agentic loop is
//!     allowed to invoke when serving a public REST request.
//!
//! ## Boundary contract
//!
//! Downstream sub-ACs may add public items here, but they must:
//!
//!   * read `CLAURST_API_KEY` (incoming X-API-Key validator) and
//!     `DEEPSEEK_API_KEY` (upstream `cc-api` credential) by those exact
//!     names — no `ANTHROPIC_API_KEY` / `API_KEY` aliases on the server
//!     path;
//!   * preserve the error-status mapping established in AC 3
//!     (non-rate-limit upstream → 502, RateLimit / 429 / 529 → 503,
//!     `ContextWindowExceeded` → 413);
//!   * preserve the `WWW-Authenticate` header on 401 responses introduced
//!     by AC 2.
//!
//! See `crates/cli/src/serve.rs` and `crates/cli/src/serve_auth.rs` for the
//! production handler-state construction and auth-middleware wiring that
//! this crate is consumed by.

pub mod handlers;
pub mod types;

pub use handlers::{ask_handler, AskErrorResponse, AskState};
pub use types::{AskRequest, AskResponse};

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::{
    body::Body,
    http::{header, Request, Response, StatusCode},
    routing::post,
    Router,
};
use cc_tools::{TodoWriteTool, Tool, WebFetchTool};
use tokio::net::TcpListener;
use tower_http::{timeout::TimeoutLayer, trace::TraceLayer};
use tracing::{info, info_span, Span};

// ---------------------------------------------------------------------------
// Restricted tool registry
// ---------------------------------------------------------------------------

/// Build the restricted tool registry used by the `/ask` endpoint.
///
/// Returns the *only* tools the agentic loop is allowed to invoke when serving
/// a public REST request:
///
///   1. `WebFetch` — read-only HTTP GET so the model can ground its answer
///      in publicly-reachable web content.
///   2. `TodoWrite` — in-process task list scratchpad; touches no filesystem,
///      starts no processes, and only mutates session-local memory.
///
/// Tools that grant write or execute capability (`Bash`, `PowerShell`,
/// `Write`/`FileWriteTool`, `Edit`/`FileEditTool`, `NotebookEdit`,
/// `EnterWorktree`, cron mutators, MCP wrappers, etc.) are intentionally
/// **not** registered here. Even read-only filesystem tools such as `Read`,
/// `Glob`, and `Grep` are excluded — the deployed container has no mounted
/// workspace, so exposing them would only surface a confusing empty
/// filesystem to the model.
///
/// Keep this list narrow: every tool added here expands the public attack
/// surface of the deployment.
///
/// The return type is `Vec<Arc<dyn Tool>>` — Arc-wrapping (rather than Box-
/// wrapping) lets the same registry be cheaply shared across the axum
/// handler state, the cc-query loop, and any sub-agent or background task
/// that wants to reference it without rebuilding the list. The cc-query
/// loop accepts `&[Arc<dyn Tool>]` directly, so no conversion is required
/// at the call site in `ask_handler`.
pub fn restricted_tools() -> Vec<Arc<dyn Tool>> {
    vec![Arc::new(WebFetchTool), Arc::new(TodoWriteTool)]
}

// ---------------------------------------------------------------------------
// Per-request timeout (mirrors Azure Container Apps ingress idle timeout)
// ---------------------------------------------------------------------------

/// Per-request deadline applied to `POST /ask` traffic, in seconds.
///
/// 240 seconds matches the Seed-mandated Azure Container Apps ingress idle
/// timeout (see `deploy/configure-ingress.sh`'s `IDLE_TIMEOUT_MINUTES=4`
/// default and the `request_timeout_seconds` ontology concept). Pinning the
/// same value at the application layer so that:
///
///   * a runaway agentic loop cannot exceed the platform-level deadline and
///     hand the client an opaque 504 from the front-door proxy,
///   * the server-side cutoff produces a structured response (the tower-http
///     `TimeoutLayer` returns `408 Request Timeout` with an empty body), and
///   * a future change to the ingress timeout can be tracked via this single
///     symbol — clients of the `cc-http` library see one source of truth.
///
/// This is a hard ceiling, not a typical-case budget. Typical agentic-loop
/// queries — even multi-round-trip ones with a few tool calls — should
/// complete in a small fraction of this window.
pub const REQUEST_TIMEOUT_SECS: u64 = 240;

/// [`Duration`] form of [`REQUEST_TIMEOUT_SECS`]. Convenience for callers that
/// want to construct their own [`TimeoutLayer`] / [`tokio::time::timeout`]
/// without duplicating the `240` literal.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(REQUEST_TIMEOUT_SECS);

/// Build a [`TimeoutLayer`] configured with [`REQUEST_TIMEOUT`].
///
/// Returned as a tower-http [`TimeoutLayer`] (not a generic `Layer<S>`) so
/// callers can compose it with any axum [`Router`] / tower service via
/// [`Router::layer`] without dealing with type-erasure.
///
/// Behaviour on timeout:
///
///   * The wrapped service's future is dropped (which Tokio cancels at the
///     next `.await` point), and
///   * tower-http synthesises a `408 Request Timeout` response with an empty
///     body. The `cc-http` handler's own `Cancelled → 504` mapping is *not*
///     reached because the layer fires above the handler — this is by design,
///     so a client can distinguish the platform-side deadline-miss (408 from
///     this layer) from a cooperative loop cancellation (504 from the
///     handler's `QueryOutcome::Cancelled` branch).
pub fn request_timeout_layer() -> TimeoutLayer {
    // `with_status_code` is the non-deprecated constructor in tower-http 0.6+
    // and lets us pin the response status explicitly. We choose
    // `408 Request Timeout` over `504 Gateway Timeout` because:
    //
    //   * 408 is the canonical "the server timed out *waiting on you*"
    //     code (RFC 9110 §15.5.9), matching what the platform-level
    //     deadline-miss really is from the client's perspective; and
    //   * 504 stays reserved for the handler's `QueryOutcome::Cancelled`
    //     path (the agentic loop cooperatively cancelled mid-flight),
    //     keeping the AC 3 status contract consistent — clients can
    //     distinguish the layer-fired hard deadline (408) from the
    //     in-handler cooperative cancellation (504).
    TimeoutLayer::with_status_code(StatusCode::REQUEST_TIMEOUT, REQUEST_TIMEOUT)
}

/// Wrap a [`Router`] in the canonical 240-second [`TimeoutLayer`].
///
/// The layer is attached via [`Router::layer`], which means it sits *outside*
/// any subsequent layers the caller adds — including any auth middleware
/// composed by the consuming binary. This is intentional: the deadline must
/// apply to the auth-middleware phase too, otherwise an extremely slow auth
/// path could exceed the ingress timeout before the handler even starts.
///
/// Returns a fresh `Router` rather than mutating the input so callers can
/// still chain further layers on top:
///
/// ```ignore
/// let app = with_request_timeout(build_router(state));
/// let app = protect_router(app, auth); // auth then runs *under* the timeout
/// ```
pub fn with_request_timeout(router: Router) -> Router {
    router.layer(request_timeout_layer())
}

// ---------------------------------------------------------------------------
// Per-request access log
// ---------------------------------------------------------------------------

/// Wrap a [`Router`] with an HTTP access-log layer that emits a structured
/// `info!` line on request entry and on response.
///
/// Apply this as the **outermost** layer in the stack so it observes every
/// request that reaches the server — including those that are synthesised
/// off by inner layers (timeout 408/504, auth 401, body-extractor 400/415,
/// route 404). Operators tailing `az containerapp logs show` see one start
/// line and one end line per request, with method, URI, declared
/// `Content-Length`, response status, and wall-clock latency. Both lines
/// share a `http_request` span, so any handler-emitted events (such as
/// `ask_handler`'s `question_len` log) inherit the request context
/// automatically.
///
/// Fields are deliberately limited to non-sensitive request metadata. The
/// request body, query string contents, and request/response headers other
/// than `Content-Length` are **not** logged — bodies may carry user prompts
/// with PII, and headers carry the `X-API-Key` credential.
pub fn with_request_logging(router: Router) -> Router {
    let trace_layer = TraceLayer::new_for_http()
        .make_span_with(|req: &Request<Body>| {
            // `Content-Length` is what the client *declared*; the actual
            // bytes read may differ (chunked encoding, truncation), but
            // declared length is what surfaces oversized prompts before any
            // body extractor runs and is the cheapest correlator for "big
            // request hit /ask".
            let content_length = req
                .headers()
                .get(header::CONTENT_LENGTH)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("-");
            info_span!(
                "http_request",
                method = %req.method(),
                uri = %req.uri(),
                content_length = %content_length,
            )
        })
        .on_request(|_req: &Request<Body>, _span: &Span| {
            info!("incoming request");
        })
        .on_response(|resp: &Response<Body>, latency: Duration, _span: &Span| {
            info!(
                status = %resp.status(),
                latency_ms = latency.as_millis() as u64,
                "request completed"
            );
        });
    router.layer(trace_layer)
}

// ---------------------------------------------------------------------------
// Router & server entry points
// ---------------------------------------------------------------------------

/// Build the axum [`Router`] hosting the `POST /ask` endpoint.
///
/// The returned router is **bare**: it has no auth middleware, no
/// timeout layer, and no shared state beyond the supplied
/// [`handlers::AskState`]. Callers that need an X-API-Key gate (the production
/// wiring in `crates/cli`) compose [`axum::middleware::from_fn_with_state`]
/// over this router via [`Router::route_layer`]. Keeping the router
/// unauthenticated by default keeps it trivially unit-testable and lets the
/// CLI choose how to attach auth without `cc-http` needing to know about
/// state types unrelated to [`crate::types`].
///
/// Currently registered routes:
///
///   * `POST /ask` → [`handlers::ask_handler`]
///
/// All other paths and all non-`POST` methods on `/ask` fall through to
/// axum's default 404 / 405 handlers, which is what we want — a public
/// deployment should expose only the documented endpoint.
pub fn build_router(state: AskState) -> Router {
    Router::new()
        .route("/ask", post(handlers::ask_handler))
        .with_state(state)
}

/// Bind a [`TcpListener`] to `addr` and serve [`build_router`] on it,
/// wrapped in the canonical 240-second [`with_request_timeout`] layer.
///
/// This is the convenience entry point used when the caller does not need
/// to hold the listener (e.g. for graceful-shutdown wiring) or apply
/// extra layers (e.g. an X-API-Key gate). The CLI binary opts into this
/// path for its `--serve` mode after first wrapping the router in its auth
/// middleware; tests and other internal callers can use it directly.
///
/// Uses `axum::serve` under the hood, which means:
///   * HTTP/1 only (matches the `axum = { features = ["http1"] }` workspace
///     pin — the deployment fronts behind Container Apps ingress so HTTP/2
///     is unnecessary at this layer);
///   * shutdown is by `await`-cancellation (e.g. tokio `select!` with a
///     shutdown signal) — no graceful-shutdown plumbing here.
///
/// The timeout is applied even for callers that don't compose extra
/// middleware so the application-layer deadline always matches the
/// platform-layer ingress idle timeout. Callers that need to swap in a
/// different deadline can build the router via
/// `build_router(state).layer(TimeoutLayer::with_status_code(status, dur))`
/// and pass it to `axum::serve` directly instead of going through this
/// entry point.
///
/// Errors:
///   * `io::Error` from `TcpListener::bind` (port in use, permission denied, …)
///   * `io::Error` propagated from the running server.
pub async fn serve(addr: SocketAddr, state: AskState) -> std::io::Result<()> {
    let listener = TcpListener::bind(addr).await?;
    let local_addr = listener.local_addr()?;
    info!(
        %local_addr,
        timeout_secs = REQUEST_TIMEOUT_SECS,
        "cc-http server listening"
    );
    axum::serve(
        listener,
        with_request_logging(with_request_timeout(build_router(state))),
    )
    .await
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Method, Request, StatusCode},
    };
    use cc_core::cost::CostTracker;
    use cc_query::QueryConfig;
    use cc_tools::{PermissionLevel, ToolContext};
    use http_body_util::BodyExt;
    use std::collections::HashSet;
    use tower::ServiceExt; // .oneshot

    // -------- helpers --------

    async fn read_body(resp: axum::response::Response) -> (StatusCode, Vec<u8>) {
        let status = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        (status, bytes.to_vec())
    }

    fn json_body(value: serde_json::Value) -> Body {
        Body::from(serde_json::to_vec(&value).unwrap())
    }

    /// Build an `AskState` suitable for router-level wiring tests.
    ///
    /// We never actually drive a real DeepSeek call from these tests — the
    /// state exists only so the axum extractor type-checks and so tests that
    /// short-circuit before the agentic loop (e.g. validation failures, 405
    /// on wrong methods, 404 on unknown paths) reach the right code path.
    fn dummy_ask_state() -> AskState {
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
            .expect("AnthropicClient construction with dummy key"),
        );
        AskState::new(client, tool_ctx, QueryConfig::default(), CostTracker::new())
    }

    // -------- restricted_tools registry guards (security-critical) --------

    /// The registry must contain exactly the two whitelisted tools — no more,
    /// no fewer. This guards against accidental future additions slipping
    /// dangerous capabilities into a public endpoint.
    #[test]
    fn restricted_tools_contains_only_web_fetch_and_todo() {
        let tools = restricted_tools();
        let names: HashSet<&str> = tools.iter().map(|t| t.name()).collect();

        assert_eq!(
            tools.len(),
            2,
            "restricted_tools() must expose exactly 2 tools, got: {:?}",
            names
        );
        assert!(
            names.contains(cc_core::constants::TOOL_NAME_WEB_FETCH),
            "WebFetch must be present, got: {:?}",
            names
        );
        assert!(
            names.contains(cc_core::constants::TOOL_NAME_TODO_WRITE),
            "TodoWrite must be present, got: {:?}",
            names
        );
    }

    /// Every tool name must be unique. (Trivially true for a 2-element list,
    /// but encoded as a regression test for any future expansion.)
    #[test]
    fn restricted_tools_have_unique_names() {
        let tools = restricted_tools();
        let mut seen = HashSet::new();
        for tool in &tools {
            assert!(
                seen.insert(tool.name().to_string()),
                "Duplicate tool name in restricted registry: {}",
                tool.name()
            );
        }
    }

    /// Hard guarantee that no write- or execute-capable tool is reachable via
    /// the /ask endpoint. If any tool ever ships at `Write`, `Execute`, or
    /// `Dangerous` from this registry, this test fails and the deployment is
    /// blocked.
    #[test]
    fn restricted_tools_are_all_read_only_or_none() {
        for tool in restricted_tools() {
            match tool.permission_level() {
                PermissionLevel::None | PermissionLevel::ReadOnly => {}
                level => panic!(
                    "Tool '{}' has permission level {:?}, which must not appear \
                     in the restricted /ask registry",
                    tool.name(),
                    level
                ),
            }
        }
    }

    /// Explicitly assert that the high-risk tool names from `cc_tools::all_tools()`
    /// are absent. Belt-and-suspenders check: the constraint document calls
    /// these out by name.
    #[test]
    fn restricted_tools_excludes_write_and_execute_tools() {
        let tools = restricted_tools();
        let names: HashSet<&str> = tools.iter().map(|t| t.name()).collect();
        let forbidden = [
            "Bash",
            "PowerShell",
            "Write",       // FileWriteTool
            "Edit",        // FileEditTool
            "Read",        // FileReadTool — no useful filesystem in the container
            "Glob",
            "Grep",
            "NotebookEdit",
            "EnterWorktree",
            "ExitWorktree",
            "CronCreate",
            "CronDelete",
            "Task",
        ];
        for name in &forbidden {
            assert!(
                !names.contains(name),
                "Tool '{}' must NOT appear in the restricted /ask registry",
                name
            );
        }
    }

    /// Each tool must produce a valid `ToolDefinition` so it can be sent to
    /// the API. Catches any tool that returns an empty schema or name.
    #[test]
    fn restricted_tools_produce_valid_definitions() {
        for tool in restricted_tools() {
            let def = tool.to_definition();
            assert!(!def.name.is_empty(), "Tool definition has empty name");
            assert!(
                !def.description.is_empty(),
                "Tool '{}' has empty description",
                def.name
            );
            assert!(
                def.input_schema.is_object(),
                "Tool '{}' input_schema must be a JSON object",
                def.name
            );
        }
    }

    // -------- build_router behaviour --------

    /// Empty / whitespace-only questions must reach the handler's validation
    /// path and produce 400 Bad Request — i.e. confirm the route is wired up
    /// and the handler is actually being invoked, not 404'd. We use an empty
    /// question because that path short-circuits before the agentic loop, so
    /// the test does not require a live upstream.
    #[tokio::test]
    async fn post_ask_with_empty_question_returns_400() {
        let app = build_router(dummy_ask_state());
        let req = Request::builder()
            .method(Method::POST)
            .uri("/ask")
            .header("content-type", "application/json")
            .body(json_body(serde_json::json!({ "question": "" })))
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    /// `GET /ask` must produce 405 Method Not Allowed: only POST is wired
    /// up. Locks out an accidental future change that would make the route
    /// promiscuously accept any method.
    #[tokio::test]
    async fn get_ask_returns_405_method_not_allowed() {
        let app = build_router(dummy_ask_state());
        let req = Request::builder()
            .method(Method::GET)
            .uri("/ask")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::METHOD_NOT_ALLOWED);
    }

    /// Other HTTP verbs on `/ask` are equally not allowed.
    #[tokio::test]
    async fn put_and_delete_on_ask_return_405() {
        for method in [Method::PUT, Method::DELETE, Method::PATCH] {
            let app = build_router(dummy_ask_state());
            let req = Request::builder()
                .method(method.clone())
                .uri("/ask")
                .body(Body::empty())
                .unwrap();
            let resp = app.oneshot(req).await.unwrap();
            assert_eq!(
                resp.status(),
                StatusCode::METHOD_NOT_ALLOWED,
                "{method} /ask should be 405"
            );
        }
    }

    /// Unknown paths must return 404 — the seed contract limits the public
    /// surface to `/ask`, so any other path (including a healthcheck-style
    /// `/health`, which the constraints explicitly forbid) must be absent.
    #[tokio::test]
    async fn unknown_paths_return_404() {
        for path in ["/", "/health", "/healthz", "/ready", "/ask/", "/asky", "/v1/ask"] {
            let app = build_router(dummy_ask_state());
            let req = Request::builder()
                .method(Method::POST)
                .uri(path)
                .header("content-type", "application/json")
                .body(json_body(serde_json::json!({ "question": "x" })))
                .unwrap();
            let resp = app.oneshot(req).await.unwrap();
            assert_eq!(
                resp.status(),
                StatusCode::NOT_FOUND,
                "path '{path}' must 404, got {}",
                resp.status()
            );
        }
    }

    /// A body missing the `question` field must produce a 4xx (axum's `Json`
    /// extractor rejects the deserialization). The handler is never invoked
    /// with a partially-built `AskRequest`.
    #[tokio::test]
    async fn missing_question_field_returns_4xx() {
        let app = build_router(dummy_ask_state());
        let req = Request::builder()
            .method(Method::POST)
            .uri("/ask")
            .header("content-type", "application/json")
            .body(json_body(serde_json::json!({})))
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert!(
            resp.status().is_client_error(),
            "missing `question` field must produce a 4xx, got {}",
            resp.status()
        );
    }

    /// Garbage body must not panic the handler — axum's extractor should
    /// surface a 4xx before any of our code runs.
    #[tokio::test]
    async fn non_json_body_returns_4xx() {
        let app = build_router(dummy_ask_state());
        let req = Request::builder()
            .method(Method::POST)
            .uri("/ask")
            .header("content-type", "application/json")
            .body(Body::from("not json at all"))
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert!(
            resp.status().is_client_error(),
            "non-JSON body must produce a 4xx, got {}",
            resp.status()
        );
    }

    /// The router must be `Clone` (axum requires it for cheap cloning across
    /// per-connection service instantiations). Lock that in so a future
    /// refactor that introduces a non-`Clone` shared state is caught here.
    #[test]
    fn build_router_returns_a_clone_router() {
        fn assert_clone<T: Clone>(_t: &T) {}
        let r = build_router(dummy_ask_state());
        assert_clone(&r);
    }

    // -------- error-envelope wire shape --------

    /// 400 responses from the handler must use the canonical
    /// `{ "error": "...", "message": "..." }` shape — the same envelope the
    /// auth middleware uses, so clients get a uniform contract.
    #[tokio::test]
    async fn empty_question_400_uses_error_envelope() {
        let app = build_router(dummy_ask_state());
        let req = Request::builder()
            .method(Method::POST)
            .uri("/ask")
            .header("content-type", "application/json")
            .body(json_body(serde_json::json!({ "question": "" })))
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = read_body(resp).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            value.get("error").and_then(|v| v.as_str()),
            Some("bad_request")
        );
        assert!(
            value.get("message").and_then(|v| v.as_str()).is_some(),
            "error envelope must carry a `message` field, got: {value}"
        );
    }

    // -------- request-timeout layer (AC 9: 240s deadline) --------

    /// Lock the timeout constants. The Seed pins this at exactly 240 s; any
    /// future drift between the application-side deadline and the Container
    /// Apps ingress idle timeout would surface as a confusing platform-side
    /// 504 instead of the structured 408 the timeout layer produces. Treat
    /// this as a contract test, not a sanity check.
    #[test]
    fn request_timeout_constant_matches_seed_contract() {
        assert_eq!(
            REQUEST_TIMEOUT_SECS, 240,
            "REQUEST_TIMEOUT_SECS must be 240 to mirror the Container Apps \
             ingress idle timeout (deploy/configure-ingress.sh \
             IDLE_TIMEOUT_MINUTES=4)"
        );
        assert_eq!(
            REQUEST_TIMEOUT,
            std::time::Duration::from_secs(240),
            "REQUEST_TIMEOUT must be the Duration form of REQUEST_TIMEOUT_SECS"
        );
    }

    /// `request_timeout_layer()` is a thin wrapper around
    /// `TimeoutLayer::new(REQUEST_TIMEOUT)`. Confirm constructing it does not
    /// panic and produces a real `TimeoutLayer` we can `.layer()` on a
    /// router. (The behavioural assertions live in the layer-fires test
    /// below.)
    #[test]
    fn request_timeout_layer_constructs_and_attaches_to_router() {
        let layer = request_timeout_layer();
        // Attaching the layer must compile and produce a usable Router.
        // We don't drive a request here — that's covered by the layered_*
        // behavioural tests below.
        let _router: Router = Router::new()
            .route("/x", post(|| async { "x" }))
            .layer(layer);
    }

    /// `with_request_timeout(router)` must return a Router that still routes
    /// fast handlers normally. The 240s deadline is many orders of magnitude
    /// above the time a unit-test handler takes, so a request that returns
    /// immediately must pass through unaffected.
    #[tokio::test]
    async fn with_request_timeout_passes_through_fast_responses() {
        let inner: Router = Router::new().route("/ping", post(|| async { "pong" }));
        let app = with_request_timeout(inner);

        let req = Request::builder()
            .method(Method::POST)
            .uri("/ping")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = read_body(resp).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, b"pong");
    }

    /// Behavioural test for the timeout layer: a handler that takes longer
    /// than the configured deadline must be cut off, and the layer must
    /// synthesise a `408 Request Timeout` response instead of letting the
    /// slow future complete. We use a custom 50 ms deadline rather than the
    /// production 240 s so the test runs in real time without virtualising
    /// the tokio clock — the underlying mechanism (`tower-http::TimeoutLayer`)
    /// is identical at any duration.
    #[tokio::test]
    async fn timeout_layer_cuts_off_slow_handler() {
        // 5-second sleep is far past the 50ms test deadline, so the layer
        // must always fire before the handler returns.
        let inner: Router = Router::new().route(
            "/slow",
            post(|| async {
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                "should-never-be-returned"
            }),
        );
        let app = inner.layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            std::time::Duration::from_millis(50),
        ));

        let start = std::time::Instant::now();
        let req = Request::builder()
            .method(Method::POST)
            .uri("/slow")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let elapsed = start.elapsed();
        let (status, body) = read_body(resp).await;

        assert_eq!(
            status,
            StatusCode::REQUEST_TIMEOUT,
            "TimeoutLayer must respond with 408 Request Timeout, got {} \
             with body {:?}",
            status,
            String::from_utf8_lossy(&body),
        );
        // The slow handler's body must NOT have been observed.
        assert_ne!(
            body, b"should-never-be-returned",
            "the timeout layer let the slow handler complete: body was {:?}",
            String::from_utf8_lossy(&body),
        );
        // Wall-clock sanity: the response must come back well before the
        // slow handler's 5-second sleep would have finished. Allow a
        // generous 2 s ceiling for CI slowness.
        assert!(
            elapsed < std::time::Duration::from_secs(2),
            "timeout layer took {:?} to respond — expected ≪ 2 s",
            elapsed,
        );
    }

    /// `with_request_logging` must be a transparent wrapper for the request
    /// path: a request that would normally produce a 400 from the handler
    /// must still produce a 400 once wrapped, with no header/body changes.
    /// The log layer's job is observability, not transformation.
    #[tokio::test]
    async fn with_request_logging_passes_through_responses() {
        let app = with_request_logging(with_request_timeout(build_router(dummy_ask_state())));
        let req = Request::builder()
            .method(Method::POST)
            .uri("/ask")
            .header("content-type", "application/json")
            .body(json_body(serde_json::json!({ "question": "" })))
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = read_body(resp).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            value.get("error").and_then(|v| v.as_str()),
            Some("bad_request"),
            "logging layer must not alter the error envelope"
        );
    }

    /// `with_request_timeout` must compose with [`build_router`] without any
    /// special handling — the production binary nests them as
    /// `with_request_timeout(build_router(state))`, optionally followed by
    /// auth, and we want to lock that shape in here so a future refactor
    /// that breaks the composition is caught at the cc-http layer.
    #[tokio::test]
    async fn with_request_timeout_wraps_build_router() {
        let app = with_request_timeout(build_router(dummy_ask_state()));

        // A bad-question request must still take the handler's 400 path
        // (the timeout layer is many orders of magnitude above the handler's
        // millisecond return time), proving the layer didn't intercept the
        // synchronous error path.
        let req = Request::builder()
            .method(Method::POST)
            .uri("/ask")
            .header("content-type", "application/json")
            .body(json_body(serde_json::json!({ "question": "" })))
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }
}
