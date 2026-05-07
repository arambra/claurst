//! API key authentication for the `/ask` REST endpoint.
//!
//! Gates inbound requests by an `X-API-Key` HTTP header. The expected key is
//! provided by the operator (in production, injected as a Container Apps
//! secret env var).
//!
//! Behavior, per the seed contract:
//!   * Missing header              → 401 Unauthorized
//!   * Header present but mismatch → 401 Unauthorized
//!   * Header present and matches  → request continues to the handler
//!
//! No OAuth, no Key Vault, no scopes — just a single shared secret.
//!
//! Constant-time comparison is used to avoid timing side-channels even though
//! the threat model (a single internal-traffic API key) does not really
//! demand it. Cheap insurance.

// Items here are consumed from the /ask handler wired up in a sibling AC; the
// module's own unit tests already exercise every public item end-to-end, so
// dead-code warnings during the parallel build window are noise.
#![allow(dead_code)]

use axum::{
    extract::{Request, State},
    http::{header, HeaderMap, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json, Router,
};
use serde_json::json;
use std::sync::Arc;
use tracing::{debug, warn};

/// Header name carrying the shared secret. Lower-cased because axum's
/// `HeaderMap` indexes by lowercase, and HTTP header names are
/// case-insensitive on the wire.
pub const API_KEY_HEADER: &str = "x-api-key";

/// Environment variable from which the expected API key is read at startup.
///
/// Standardized in AC 7's secret-injection contract: the Container Apps
/// `claurst-api-key` secret is wired to this env var, and the Rust binary
/// reads it once at boot. Do **not** introduce alternate spellings
/// (`API_KEY`, `ANTHROPIC_API_KEY`, …) on the server path — they would let
/// a misconfigured deployment silently start without auth.
pub const API_KEY_ENV_VAR: &str = "CLAURST_API_KEY";

/// Shared state injected into the auth middleware.
///
/// Wrapped in `Arc` so the axum `State` extractor can clone it cheaply on
/// every request without copying the secret bytes.
#[derive(Clone, Debug)]
pub struct ApiKeyAuth {
    expected: Arc<Vec<u8>>,
}

impl ApiKeyAuth {
    /// Build an auth gate from a configured key.
    ///
    /// An empty key is rejected: an empty shared secret would silently let
    /// every "anonymous" request through, which is the opposite of what an
    /// operator turning on auth would expect.
    pub fn new(expected_key: impl Into<String>) -> Result<Self, ApiKeyConfigError> {
        let key = expected_key.into();
        if key.is_empty() {
            return Err(ApiKeyConfigError::EmptyKey);
        }
        Ok(Self {
            expected: Arc::new(key.into_bytes()),
        })
    }

    /// Build an auth gate by reading [`API_KEY_ENV_VAR`] from the process
    /// environment.
    ///
    /// This is the canonical startup path for the production server: the
    /// `CLAURST_API_KEY` env var is injected from the Container Apps secret
    /// (see `deploy/secrets/setup-secrets.sh`), and the binary refuses to
    /// start auth-less if it is missing or empty. Both failure modes are
    /// distinct so an operator's logs make the misconfiguration obvious:
    ///
    ///   * `MissingEnv` — the env var was not set at all (likely the secret
    ///     wasn't wired to the container);
    ///   * `EmptyKey`   — the env var was set but empty (likely the secret
    ///     value itself is blank).
    pub fn from_env() -> Result<Self, ApiKeyConfigError> {
        let value = std::env::var(API_KEY_ENV_VAR)
            .map_err(|_| ApiKeyConfigError::MissingEnv(API_KEY_ENV_VAR))?;
        Self::new(value)
    }

    /// Verify a candidate key against the configured one in constant time.
    pub fn verify(&self, provided: &[u8]) -> bool {
        constant_time_eq(provided, &self.expected)
    }

    /// Apply the gate to a [`HeaderMap`] without going through axum.
    /// Useful for unit tests and for any future framework swap.
    pub fn check_headers(&self, headers: &HeaderMap) -> Result<(), AuthFailure> {
        let raw = headers
            .get(API_KEY_HEADER)
            .ok_or(AuthFailure::Missing)?
            .as_bytes();

        if self.verify(raw) {
            Ok(())
        } else {
            Err(AuthFailure::Mismatch)
        }
    }
}

/// Why an auth check failed. Both variants map to HTTP 401.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthFailure {
    /// `X-API-Key` header was absent.
    Missing,
    /// Header was present but the value did not match.
    Mismatch,
}

impl AuthFailure {
    pub fn as_str(&self) -> &'static str {
        match self {
            AuthFailure::Missing => "missing X-API-Key header",
            AuthFailure::Mismatch => "invalid X-API-Key",
        }
    }
}

/// Reasons configuring the gate can fail at startup.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiKeyConfigError {
    /// The configured / supplied key was the empty string.
    EmptyKey,
    /// The expected env var was not present in the process environment.
    /// Carries the variable name so the operator's log line is actionable.
    MissingEnv(&'static str),
}

impl std::fmt::Display for ApiKeyConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiKeyConfigError::EmptyKey => f.write_str("API key must not be empty"),
            ApiKeyConfigError::MissingEnv(name) => write!(
                f,
                "API key env var '{}' is not set — refusing to start without auth",
                name
            ),
        }
    }
}

impl std::error::Error for ApiKeyConfigError {}

/// Constant-time byte comparison.
///
/// Returns `false` for length mismatches (length is not secret here — the
/// configured key length is known to the operator) and otherwise XORs each
/// pair of bytes, accumulating into a single byte. This avoids the early-exit
/// short-circuit that a naive `==` would produce.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

// ---------------------------------------------------------------------------
// axum integration
// ---------------------------------------------------------------------------

/// Axum middleware: enforce `X-API-Key` on every wrapped route.
///
/// Reject with `401 Unauthorized` and a small JSON error body when the header
/// is missing or wrong; otherwise hand the request to `next`.
///
/// Wire it up with `axum::middleware::from_fn_with_state`:
/// ```ignore
/// let auth = ApiKeyAuth::new(std::env::var("CLAURST_API_KEY")?)?;
/// let app = Router::new()
///     .route("/ask", post(ask_handler))
///     .route_layer(axum::middleware::from_fn_with_state(auth, require_api_key));
/// ```
pub async fn require_api_key(
    State(auth): State<ApiKeyAuth>,
    request: Request,
    next: Next,
) -> Response {
    match auth.check_headers(request.headers()) {
        Ok(()) => {
            debug!("api key accepted");
            next.run(request).await
        }
        Err(failure) => {
            // Log at warn level but never echo the supplied key — even if it
            // is wrong, it is still a secret somebody intended to use.
            warn!(reason = failure.as_str(), "api key check failed");
            unauthorized_response(failure)
        }
    }
}

/// Wrap an existing axum [`Router`] with the `X-API-Key` gate.
///
/// The auth middleware is attached as a `route_layer`, which means axum
/// runs it **before** dispatching to any of `router`'s handlers. A request
/// missing or carrying the wrong key never sees the inner handler — the
/// middleware short-circuits with a `401 Unauthorized` JSON envelope and a
/// `WWW-Authenticate: ApiKey realm="claurst"` header.
///
/// This is the canonical composition the production binary (`claude
/// --serve` mode) uses when wiring `cc_http::build_router()` into a serving
/// stack:
///
/// ```ignore
/// let auth = ApiKeyAuth::from_env()?;
/// let app = protect_router(cc_http::build_router(), auth);
/// axum::serve(listener, app).await?;
/// ```
///
/// Returning a fresh `Router` (rather than mutating the input in place) is
/// idiomatic for axum and lets callers chain further layers — for instance,
/// a tower-http `TimeoutLayer` mirroring the 240s ingress timeout:
///
/// ```ignore
/// use std::time::Duration;
/// use tower_http::timeout::TimeoutLayer;
///
/// let auth = ApiKeyAuth::from_env()?;
/// let app = protect_router(cc_http::build_router(), auth)
///     .layer(TimeoutLayer::new(Duration::from_secs(240)));
/// ```
pub fn protect_router(router: Router, auth: ApiKeyAuth) -> Router {
    router.route_layer(axum::middleware::from_fn_with_state(auth, require_api_key))
}

/// Build the canonical 401 response — JSON body, `WWW-Authenticate` header
/// hinting that an API key is expected.
fn unauthorized_response(failure: AuthFailure) -> Response {
    let body = Json(json!({
        "error": "unauthorized",
        "message": failure.as_str(),
    }));
    let mut response = (StatusCode::UNAUTHORIZED, body).into_response();
    response.headers_mut().insert(
        header::WWW_AUTHENTICATE,
        // `ApiKey` is not a registered HTTP auth scheme, but it is the
        // conventional value used by API gateways for shared-secret schemes.
        "ApiKey realm=\"claurst\"".parse().unwrap(),
    );
    // Marker to disambiguate axum-default 401s from our own in tests/logs.
    response
        .headers_mut()
        .insert("x-claurst-auth", "denied".parse().unwrap());
    response
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{HeaderValue, Request},
        routing::post,
        Router,
    };
    use http_body_util::BodyExt;
    use tower::ServiceExt; // .oneshot

    // -------- pure-function tests (no axum routing) --------

    #[test]
    fn rejects_empty_configured_key() {
        let err = ApiKeyAuth::new("").unwrap_err();
        assert!(matches!(err, ApiKeyConfigError::EmptyKey));
    }

    #[test]
    fn accepts_matching_key() {
        let auth = ApiKeyAuth::new("super-secret").unwrap();
        assert!(auth.verify(b"super-secret"));
    }

    #[test]
    fn rejects_wrong_key() {
        let auth = ApiKeyAuth::new("super-secret").unwrap();
        assert!(!auth.verify(b"wrong"));
        assert!(!auth.verify(b"super-secre")); // shorter
        assert!(!auth.verify(b"super-secrett")); // longer
        assert!(!auth.verify(b"")); // empty
    }

    #[test]
    fn check_headers_missing_returns_missing() {
        let auth = ApiKeyAuth::new("k").unwrap();
        let headers = HeaderMap::new();
        assert_eq!(auth.check_headers(&headers), Err(AuthFailure::Missing));
    }

    #[test]
    fn check_headers_wrong_returns_mismatch() {
        let auth = ApiKeyAuth::new("expected").unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(API_KEY_HEADER, HeaderValue::from_static("wrong"));
        assert_eq!(auth.check_headers(&headers), Err(AuthFailure::Mismatch));
    }

    #[test]
    fn check_headers_correct_returns_ok() {
        let auth = ApiKeyAuth::new("expected").unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(API_KEY_HEADER, HeaderValue::from_static("expected"));
        assert!(auth.check_headers(&headers).is_ok());
    }

    #[test]
    fn header_lookup_is_case_insensitive() {
        // HTTP header names are case-insensitive; verify that a request that
        // sends `X-API-Key` (mixed case) lands in the same axum HeaderMap
        // slot we look up with the lowercase constant.
        let auth = ApiKeyAuth::new("expected").unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            http::HeaderName::from_static("x-api-key"),
            HeaderValue::from_static("expected"),
        );
        assert!(auth.check_headers(&headers).is_ok());
    }

    // -------- axum integration tests --------

    /// Build a tiny router that protects `/ask` with the auth middleware
    /// and returns "ok" from the handler if the request gets through.
    fn protected_router(key: &str) -> Router {
        let auth = ApiKeyAuth::new(key).unwrap();
        Router::new()
            .route("/ask", post(|| async { "ok" }))
            .route_layer(axum::middleware::from_fn_with_state(
                auth,
                require_api_key,
            ))
    }

    async fn body_to_string(resp: Response) -> (StatusCode, String) {
        let status = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        (status, String::from_utf8(bytes.to_vec()).unwrap())
    }

    #[tokio::test]
    async fn missing_header_returns_401() {
        let app = protected_router("the-secret");
        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = body_to_string(resp).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert!(
            body.contains("missing X-API-Key header"),
            "body was: {body}"
        );
    }

    #[tokio::test]
    async fn empty_header_value_returns_401() {
        let app = protected_router("the-secret");
        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .header(API_KEY_HEADER, "")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn wrong_header_returns_401() {
        let app = protected_router("the-secret");
        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .header(API_KEY_HEADER, "not-the-secret")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = body_to_string(resp).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert!(body.contains("invalid X-API-Key"), "body was: {body}");
    }

    #[tokio::test]
    async fn correct_header_passes_through() {
        let app = protected_router("the-secret");
        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .header(API_KEY_HEADER, "the-secret")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = body_to_string(resp).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "ok");
    }

    #[tokio::test]
    async fn mixed_case_header_passes_through() {
        // Verifies the constraint that real clients sending `X-API-Key`
        // (the canonical mixed-case spelling from the Seed) succeed.
        let app = protected_router("the-secret");
        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .header("X-API-Key", "the-secret")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn unauthorized_response_includes_www_authenticate() {
        let app = protected_router("k");
        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        let www = resp
            .headers()
            .get(header::WWW_AUTHENTICATE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        assert!(www.starts_with("ApiKey"), "got: {www}");
    }

    // -------- from_env() --------
    //
    // These tests mutate process environment, so they share a `Mutex` to
    // serialise: cargo runs `#[test]` items in a single binary in parallel
    // by default, and a leak between tests would cause flaky pass/fail. The
    // mutex lives for the whole `mod tests` and is acquired for the full
    // lifetime of each from-env test.

    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    /// RAII guard that captures the current value of an env var, lets the
    /// test mutate it, and restores the original on `Drop`. Avoids leaking
    /// `CLAURST_API_KEY` mutations into other tests in the same process.
    struct EnvGuard {
        name: &'static str,
        original: Option<String>,
    }

    impl EnvGuard {
        fn capture(name: &'static str) -> Self {
            Self {
                name,
                original: std::env::var(name).ok(),
            }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            // SAFETY: env mutation is gated by ENV_LOCK in every from-env
            // test; outside of those tests this code does not run.
            unsafe {
                match &self.original {
                    Some(v) => std::env::set_var(self.name, v),
                    None => std::env::remove_var(self.name),
                }
            }
        }
    }

    #[test]
    fn from_env_reads_claurst_api_key() {
        let _lock = ENV_LOCK.lock().unwrap();
        let _guard = EnvGuard::capture(API_KEY_ENV_VAR);
        unsafe {
            std::env::set_var(API_KEY_ENV_VAR, "the-configured-secret");
        }

        let auth = ApiKeyAuth::from_env().expect("from_env should succeed");
        assert!(auth.verify(b"the-configured-secret"));
        assert!(!auth.verify(b"wrong"));
    }

    #[test]
    fn from_env_returns_missing_when_var_unset() {
        let _lock = ENV_LOCK.lock().unwrap();
        let _guard = EnvGuard::capture(API_KEY_ENV_VAR);
        unsafe {
            std::env::remove_var(API_KEY_ENV_VAR);
        }

        let err = ApiKeyAuth::from_env().unwrap_err();
        assert!(
            matches!(err, ApiKeyConfigError::MissingEnv(name) if name == API_KEY_ENV_VAR),
            "expected MissingEnv({API_KEY_ENV_VAR}), got: {err:?}",
        );
        // Display message must mention the env var by name so the operator's
        // log line is actionable.
        let rendered = err.to_string();
        assert!(
            rendered.contains(API_KEY_ENV_VAR),
            "Display should name the env var; got: {rendered}",
        );
    }

    #[test]
    fn from_env_returns_empty_when_var_blank() {
        let _lock = ENV_LOCK.lock().unwrap();
        let _guard = EnvGuard::capture(API_KEY_ENV_VAR);
        unsafe {
            std::env::set_var(API_KEY_ENV_VAR, "");
        }

        let err = ApiKeyAuth::from_env().unwrap_err();
        assert!(matches!(err, ApiKeyConfigError::EmptyKey));
    }

    #[test]
    fn api_key_env_var_is_claurst_api_key() {
        // Lock in the env-var name so that future refactors can't silently
        // change which secret the server reads. Per AC 7's contract the
        // expected name is exactly `CLAURST_API_KEY`.
        assert_eq!(API_KEY_ENV_VAR, "CLAURST_API_KEY");
    }

    // -------- protect_router --------
    //
    // These tests assert that the auth check runs *before* the wrapped
    // router's handler — both by observing that handlers never see
    // unauthorized requests and by structurally inspecting which side
    // produces the response.

    /// A handler that flips a shared atomic so tests can detect whether
    /// the auth gate let the request through to it.
    fn flag_router(flag: Arc<std::sync::atomic::AtomicBool>) -> Router {
        let flagged = flag.clone();
        Router::new().route(
            "/ask",
            post(move || {
                let flagged = flagged.clone();
                async move {
                    flagged.store(true, std::sync::atomic::Ordering::SeqCst);
                    "handler-ran"
                }
            }),
        )
    }

    #[tokio::test]
    async fn protect_router_blocks_request_before_handler_when_key_missing() {
        let flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let inner = flag_router(flag.clone());
        let auth = ApiKeyAuth::new("the-secret").unwrap();
        let app = protect_router(inner, auth);

        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        // Critical: the handler must NEVER have observed this request.
        assert!(
            !flag.load(std::sync::atomic::Ordering::SeqCst),
            "handler ran despite missing X-API-Key — middleware did not gate before handler"
        );
    }

    #[tokio::test]
    async fn protect_router_blocks_request_before_handler_when_key_wrong() {
        let flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let inner = flag_router(flag.clone());
        let auth = ApiKeyAuth::new("the-secret").unwrap();
        let app = protect_router(inner, auth);

        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .header(API_KEY_HEADER, "not-the-secret")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        assert!(
            !flag.load(std::sync::atomic::Ordering::SeqCst),
            "handler ran despite wrong X-API-Key — middleware did not gate before handler"
        );
    }

    #[tokio::test]
    async fn protect_router_dispatches_to_handler_when_key_correct() {
        let flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let inner = flag_router(flag.clone());
        let auth = ApiKeyAuth::new("the-secret").unwrap();
        let app = protect_router(inner, auth);

        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .header(API_KEY_HEADER, "the-secret")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = body_to_string(resp).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "handler-ran");
        assert!(
            flag.load(std::sync::atomic::Ordering::SeqCst),
            "handler did not run for an authorized request"
        );
    }

    #[tokio::test]
    async fn protect_router_preserves_www_authenticate_on_401() {
        let inner = Router::new().route("/ask", post(|| async { "ok" }));
        let auth = ApiKeyAuth::new("k").unwrap();
        let app = protect_router(inner, auth);

        let req = Request::builder()
            .method("POST")
            .uri("/ask")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        let www = resp
            .headers()
            .get(header::WWW_AUTHENTICATE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        assert!(
            www.starts_with("ApiKey"),
            "WWW-Authenticate header missing/invalid: {www}",
        );
    }
}
