//! Wire types for the synchronous `POST /ask` REST endpoint.
//!
//! This module defines the canonical inbound request body and outbound
//! success-response body for the `/ask` route. They live in `cc-http` (rather
//! than in the binary crate) so that:
//!
//!   * the axum handler, the auth middleware, and any future client/test
//!     harness can all share a single source of truth for the wire shape;
//!   * the JSON contract can be unit-tested without spinning up a server or
//!     pulling in `cc-query` / `cc-api`.
//!
//! ## Wire contract (locked)
//!
//! Inbound:
//!
//! ```json
//! { "question": "<user's natural-language question>" }
//! ```
//!
//! Outbound (success):
//!
//! ```json
//! { "answer": "<final synthesized answer>" }
//! ```
//!
//! Both shapes are intentionally minimal. The seed contract for this endpoint
//! forbids structured response metadata (no token counts, no tool-invocation
//! traces, no model identifier), and the request side carries no session id,
//! message history, or tool pre-selection — `/ask` is a single-turn,
//! stateless endpoint.
//!
//! Error envelopes are produced at the handler / middleware layer and are not
//! defined here, since failure-path JSON is shared with the auth middleware
//! and is owned by whatever module emits the `Response`.

use serde::{Deserialize, Serialize};

/// Inbound JSON body for `POST /ask`.
///
/// The payload carries a single field, `question`, which is the user's
/// natural-language question. Validation (non-empty, post-trim) is performed
/// in the handler — at the wire-deserialization layer we only require that
/// the field is present and is a string. A body missing the `question` field
/// (e.g. `{}`) must fail to deserialize so axum's `Json` extractor returns a
/// 4xx before any handler code runs.
///
/// `Deserialize` is required (axum reads this from the request body via the
/// `Json` extractor); `Serialize` is intentionally **not** derived so we
/// cannot accidentally echo a request body back to a caller as a response.
#[derive(Debug, Clone, Deserialize)]
pub struct AskRequest {
    /// The user's natural-language question. Validated and trimmed by the
    /// handler before being forwarded to the agentic loop.
    pub question: String,
}

/// Successful response body for `POST /ask`.
///
/// Carries only the synthesized final-turn answer text. Token counts,
/// tool-invocation traces, model identifiers, and turn counts are
/// deliberately omitted — the seed contract forbids surfacing structured
/// response metadata, both to keep the public contract minimal and to limit
/// fingerprinting of the deployment.
///
/// `Serialize` is required for axum's `Json` responder; `Deserialize` is
/// also derived so that integration tests, client crates, and golden-file
/// fixtures can round-trip through the wire shape without ad-hoc parsing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AskResponse {
    /// The model's final answer text, joined across any text content blocks
    /// in the assistant's last message.
    pub answer: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    // ------------------------------------------------------------------
    // AskRequest deserialization
    // ------------------------------------------------------------------

    /// The canonical happy-path body — a single `question` string field —
    /// must deserialize into an `AskRequest` carrying that exact value.
    #[test]
    fn ask_request_deserializes_canonical_body() {
        let body = serde_json::json!({ "question": "what time is it?" });
        let parsed: AskRequest = serde_json::from_value(body).unwrap();
        assert_eq!(parsed.question, "what time is it?");
    }

    /// Multi-line / Unicode question content must round-trip through serde
    /// untouched — the handler is responsible for any trimming/validation
    /// downstream of deserialization.
    #[test]
    fn ask_request_preserves_unicode_and_newlines() {
        let body = serde_json::json!({
            "question": "Explain 円周率 (π)\nin two short paragraphs.",
        });
        let parsed: AskRequest = serde_json::from_value(body).unwrap();
        assert_eq!(parsed.question, "Explain 円周率 (π)\nin two short paragraphs.");
    }

    /// A body missing the `question` field must fail to deserialize so
    /// axum's `Json` extractor surfaces a 4xx before the handler runs.
    #[test]
    fn ask_request_rejects_missing_question() {
        let body = serde_json::json!({});
        let result: Result<AskRequest, _> = serde_json::from_value(body);
        assert!(result.is_err(), "missing `question` field must error");
    }

    /// The wire field is named `question`, not `q` / `prompt` / `query`.
    /// Lock that name so a stray rename in the type can't silently break
    /// deployed clients.
    #[test]
    fn ask_request_rejects_misnamed_field() {
        for body in [
            serde_json::json!({ "q": "hi" }),
            serde_json::json!({ "prompt": "hi" }),
            serde_json::json!({ "query": "hi" }),
        ] {
            let result: Result<AskRequest, _> = serde_json::from_value(body);
            assert!(
                result.is_err(),
                "expected misnamed-field body to fail: {:?}",
                result.as_ref().ok().map(|r| r.question.as_str())
            );
        }
    }

    /// A non-string `question` (e.g. number, array, object, null) must fail
    /// to deserialize — serde's default behaviour, but we lock it to guard
    /// against any future `#[serde(...)]` attribute that would loosen it.
    #[test]
    fn ask_request_rejects_non_string_question() {
        for body in [
            serde_json::json!({ "question": 42 }),
            serde_json::json!({ "question": ["one", "two"] }),
            serde_json::json!({ "question": { "nested": "object" } }),
            serde_json::json!({ "question": null }),
            serde_json::json!({ "question": true }),
        ] {
            let result: Result<AskRequest, _> = serde_json::from_value(body);
            assert!(
                result.is_err(),
                "expected non-string `question` body to fail to deserialize"
            );
        }
    }

    // ------------------------------------------------------------------
    // AskResponse serialization
    // ------------------------------------------------------------------

    /// The response shape must be exactly `{ "answer": "..." }` — no token
    /// counts, no tool traces, no model identifier. The seed contract is
    /// explicit that structured metadata is forbidden, so this test acts as
    /// a regression guard against accidental field additions.
    #[test]
    fn ask_response_serializes_with_only_answer_field() {
        let body = AskResponse {
            answer: "42".to_string(),
        };
        let json = serde_json::to_value(&body).unwrap();
        assert_eq!(json, serde_json::json!({ "answer": "42" }));
    }

    /// Field count check on the serialized JSON object — fail loudly if
    /// somebody adds a sibling field to `AskResponse` without updating the
    /// seed contract.
    #[test]
    fn ask_response_has_exactly_one_field() {
        let body = AskResponse {
            answer: "anything".to_string(),
        };
        let json = serde_json::to_value(&body).unwrap();
        let obj = json.as_object().expect("AskResponse must serialize as JSON object");
        assert_eq!(
            obj.len(),
            1,
            "AskResponse must have exactly one wire field, got: {:?}",
            obj.keys().collect::<Vec<_>>()
        );
        assert!(obj.contains_key("answer"), "missing `answer` field");
    }

    /// Empty answers are allowed at the type level — emptiness checking is a
    /// handler-level concern, not a wire-format concern.
    #[test]
    fn ask_response_serializes_empty_answer() {
        let body = AskResponse {
            answer: String::new(),
        };
        let json = serde_json::to_value(&body).unwrap();
        assert_eq!(json, serde_json::json!({ "answer": "" }));
    }

    /// Multi-line / Unicode answers must round-trip through serde untouched.
    #[test]
    fn ask_response_round_trips_unicode_and_newlines() {
        let original = AskResponse {
            answer: "Hello, 世界!\nLine two — ✓".to_string(),
        };
        let json = serde_json::to_string(&original).unwrap();
        let restored: AskResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.answer, original.answer);
    }
}
