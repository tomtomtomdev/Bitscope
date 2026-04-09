import Foundation

/// Scrubs sensitive patterns from OCR text before it lands in SQLite or
/// JSONL. Runs before insertion, never after — once redacted, the raw
/// text is gone. Each pattern replaces its match with a fixed tag so
/// downstream tools can still see that *something* was there.
enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        func rx(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        return [
            // Email addresses
            (rx(#"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#),
             "[REDACTED_EMAIL]"),

            // Credit/debit card numbers (13-19 digits, optionally grouped)
            (rx(#"\b(?:\d[\s\-]?){13,19}\b"#),
             "[REDACTED_CARD]"),

            // Bearer / API tokens: "Bearer <token>" or standalone hex/base64
            // tokens ≥ 32 chars (common API key length).
            (rx(#"(?i)bearer\s+[A-Za-z0-9\-._~+/]+=*"#),
             "[REDACTED_BEARER]"),
            (rx(#"\b[A-Za-z0-9_\-]{32,}\b"#),
             "[REDACTED_TOKEN]"),

            // AWS-style keys (AKIA…)
            (rx(#"\bAKIA[0-9A-Z]{16}\b"#),
             "[REDACTED_AWS_KEY]"),

            // Generic "secret"/"password"/"token" key=value pairs
            (rx(#"(?i)(?:password|secret|token|api_?key)\s*[:=]\s*\S+"#),
             "[REDACTED_KV]"),
        ]
    }()

    /// Returns a copy of `text` with sensitive patterns replaced.
    static func redact(_ text: String) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        for (regex, replacement) in rules {
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range,
                withTemplate: replacement
            )
        }
        return result
    }
}
