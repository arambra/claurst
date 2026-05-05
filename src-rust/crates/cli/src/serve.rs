// HTTP server mode for claude-code.
//
// This module is a thin shim that re-exports the canonical implementations
// from the `cc-http` crate so existing call-sites in this binary keep
// compiling while the agentic-loop wiring lives in one place.
//
// As of sub-AC 3.2 the production agentic-loop invocation, restricted tool
// registry, error-status mapping, and `AskState` builder live in
// `cc_http::handlers` and `cc_http`. The `claude-code` binary opts into
// server mode by constructing an `AskState` and handing it to
// `cc_http::build_router` (or `cc_http::serve`); auth is layered on top by
// the X-API-Key middleware in `serve_auth.rs`.
//
// The re-exports below preserve the names that the CLI binary used before
// the migration so any code paths (tests, future wiring) can keep referring
// to `crate::serve::ask_handler` / `crate::serve::AskState` /
// `crate::serve::restricted_tools` without forcing a synchronous rename.

#![allow(dead_code)] // Wired into the binary via a follow-up sub-AC.
// `pub use` re-exports are consumed only by tests in this module and by the
// (still-pending) `--serve` wiring in the binary. Until that wiring lands,
// rustc warns about unused `pub use` imports — silence that in exactly the
// scope of this shim so the workspace build stays warning-free.
#![allow(unused_imports)]

pub use cc_http::{
    ask_handler, restricted_tools, AskErrorResponse, AskRequest, AskResponse, AskState,
};

#[cfg(test)]
mod tests {
    use super::*;

    /// Sanity check: the re-exported `restricted_tools` is the cc-http
    /// implementation, which the cc-http test suite already pins to exactly
    /// `WebFetch` + `TodoWrite`. We re-assert here so a future accidental
    /// override at the cli-shim layer would also be caught.
    #[test]
    fn restricted_tools_reexport_matches_cc_http() {
        // Bind the registry to a `let` so the &str references collected into
        // the HashSet keep their backing tool objects alive.
        let tools = restricted_tools();
        let names: std::collections::HashSet<&str> =
            tools.iter().map(|t| t.name()).collect();
        assert_eq!(names.len(), 2, "expected exactly 2 tools, got: {:?}", names);
        assert!(names.contains(cc_core::constants::TOOL_NAME_WEB_FETCH));
        assert!(names.contains(cc_core::constants::TOOL_NAME_TODO_WRITE));
    }

    /// Confirm the AskState/AskRequest/AskResponse types are the cc-http
    /// types verbatim (i.e. zero-cost re-export, not a wrapping shim).
    /// Locks out a future hand-edit that would silently introduce a
    /// type-divergence between the cli and cc-http surfaces.
    #[test]
    fn types_are_reexported_from_cc_http() {
        fn assert_same_type<T: 'static>(_: &T, _: std::marker::PhantomData<T>) {}
        let req = AskRequest {
            question: "x".to_string(),
        };
        assert_same_type(&req, std::marker::PhantomData::<cc_http::AskRequest>);
        let resp = AskResponse {
            answer: "x".to_string(),
        };
        assert_same_type(&resp, std::marker::PhantomData::<cc_http::AskResponse>);
    }
}
