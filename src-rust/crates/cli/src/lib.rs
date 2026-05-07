//! Library surface of the `claude-code` crate.
//!
//! The bulk of the CLI is driven from `main.rs` (the binary), but the server-mode
//! modules — `serve` and `serve_auth` — also need to be reachable from
//! integration tests under `crates/cli/tests/`. Cargo's binary-only crates are
//! invisible to integration tests; declaring this `lib.rs` exposes the
//! production server composition (auth middleware + bare `cc_http` router) as a
//! library that tests can link against and drive end-to-end.
//!
//! Nothing else is re-exposed: the OAuth flow, the TUI loop, the headless
//! runner, and clap argument plumbing all stay private to the binary, where
//! they belong.
//!
//! ## Boundary contract
//!
//! Items published here must mirror the same env-var / status-code contracts
//! that AC 2 / AC 3 / AC 7 baked into the binary:
//!
//!   * `serve_auth` reads `CLAURST_API_KEY` (no aliases) and emits
//!     `WWW-Authenticate: ApiKey realm="claurst"` on 401;
//!   * `serve` re-exports `cc_http`'s `AskState` / `restricted_tools` /
//!     `AskRequest` / `AskResponse` verbatim so that the integration tests and
//!     any future server wiring share a single source of truth for the wire
//!     types and the restricted tool registry.
//!
//! See `crates/cli/tests/serve_integration.rs` for the end-to-end auth-failure
//! and happy-path tests that consume this surface.

pub mod serve;
pub mod serve_auth;
