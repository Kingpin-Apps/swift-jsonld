import Foundation

/// Internal helpers shared between `ToRDF` and `FromRDF` for the lexical
/// forms of RDF literals — XSD canonical numbers and JSON-canonicalized
/// `rdf:JSON` values.

/// Lexical-form well-formedness checks for RDF terms.
///
/// JSON-LD's [Deserialize JSON-LD to RDF Algorithm §10](https://www.w3.org/TR/json-ld11-api/#deserialize-json-ld-to-rdf-algorithm)
/// requires the processor to drop quads whose IRIs would not survive
/// N-Quads serialization and quads with non-BCP-47 language tags. The
/// checks are intentionally lenient — only "definitely bad" inputs are
/// rejected; ambiguous edge cases pass through.
enum RDFTerm {
    /// True when `s` is a plausible IRI: no whitespace, no control
    /// characters, no characters reserved by the N-Triples / N-Quads
    /// grammar (`<`, `>`, `"`, `{`, `}`, `|`, `\\`, `^`, backtick),
    /// and an `irelative-part` must look absolute (start with a
    /// scheme).
    static func isWellFormedIRI(_ s: String) -> Bool {
        if s.isEmpty { return false }
        var hashCount = 0
        for scalar in s.unicodeScalars {
            if scalar.value < 0x20 { return false }
            switch scalar {
            case " ", "\"", "<", ">", "{", "}", "|", "\\", "^", "`":
                return false
            case "#":
                hashCount += 1
                // RFC 3986: at most one `#` (the fragment delimiter).
                if hashCount > 1 { return false }
            default:
                break
            }
        }
        // Must contain a scheme separator (`:`) before any path char.
        guard let colon = s.firstIndex(of: ":") else { return false }
        let scheme = s[..<colon]
        if scheme.isEmpty { return false }
        let first = scheme.first!
        if !first.isLetter { return false }
        for ch in scheme.dropFirst() {
            if !(ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == ".") {
                return false
            }
        }
        return true
    }

    /// True when `tag` is a syntactically valid BCP 47 language tag.
    ///
    /// Recognizes the common shape `primary-subtag (-subtag)*` where
    /// `primary-subtag` is 1–8 letters and each subsequent subtag is
    /// 1–8 alphanumerics. Doesn't enforce IANA registry.
    static func isWellFormedLanguageTag(_ tag: String) -> Bool {
        if tag.isEmpty { return false }
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        if parts.isEmpty { return false }
        for (idx, part) in parts.enumerated() {
            if part.isEmpty { return false }
            if part.count > 8 { return false }
            if idx == 0 {
                for ch in part {
                    if !ch.isLetter { return false }
                }
            } else {
                for ch in part {
                    if !ch.isLetter, !ch.isNumber { return false }
                }
            }
        }
        return true
    }
}

enum XSDNumber {
    /// XSD canonical double — [XSD §3.2.5 lexical mapping](https://www.w3.org/TR/xmlschema11-2/#double).
    ///
    /// The lexical form is `m E n` where `m` is a decimal in the range
    /// `[1, 10)` (or `0`), with at least one digit after the `.`, and
    /// `n` is an integer exponent with no `+` prefix.
    /// Examples: `1.0E21`, `5.3E0`, `9.9E0`, `1.2345E2`.
    static func canonicalDouble(_ d: Double) -> String {
        if d == 0 { return "0.0E0" }
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "INF" : "-INF" }

        let neg = d < 0
        let absD = abs(d)
        // Decompose into mantissa in [1, 10) and integer exponent.
        let exp = Int(floor(log10(absD)))
        let mantissa = absD / pow(10.0, Double(exp))

        // Render mantissa with enough precision but trim trailing zeros.
        var mStr = String(format: "%.15g", mantissa)

        // Ensure a decimal point — XSD requires at least one fractional digit.
        if !mStr.contains(".") { mStr += ".0" }

        // Trim trailing zeros after the decimal but keep at least one.
        if let dot = mStr.firstIndex(of: ".") {
            var end = mStr.endIndex
            while end > mStr.index(after: dot) {
                let prev = mStr.index(before: end)
                if mStr[prev] == "0" { end = prev } else { break }
            }
            // Don't strip the digit right after the decimal point.
            let minEnd = mStr.index(dot, offsetBy: 2)
            if end < minEnd { end = minEnd }
            mStr = String(mStr[..<end])
        }

        return "\(neg ? "-" : "")\(mStr)E\(exp)"
    }
}

/// JSON Canonicalization Scheme — [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785).
///
/// Used for `@type: @json` value-object emission to N-Quads: the lexical
/// form of an `rdf:JSON` literal is the JCS-canonical serialization of
/// the underlying JSON value.
enum JCS {
    static func canonicalize(_ value: JSONLD.JSON) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return canonicalNumber(d)
        case .string(let s): return encodeString(s)
        case .array(let arr):
            let parts = arr.map { canonicalize($0) }
            return "[\(parts.joined(separator: ","))]"
        case .object(let map):
            let keys = map.keys.sorted { lhs, rhs in
                // RFC 8785 §3.2.3 — sort by UTF-16 code units.
                let l = Array(lhs.utf16)
                let r = Array(rhs.utf16)
                for i in 0..<min(l.count, r.count) {
                    if l[i] != r[i] { return l[i] < r[i] }
                }
                return l.count < r.count
            }
            let parts = keys.map { k -> String in
                "\(encodeString(k)):\(canonicalize(map[k]!))"
            }
            return "{\(parts.joined(separator: ","))}"
        }
    }

    /// RFC 8785 §3.2.2.3 — ECMA-262 §7.1.12.1 ToString for numbers.
    /// Swift's default `String(double)` produces the shortest
    /// round-trippable form and includes the `+` sign on positive
    /// exponents (`1e+30`), matching the ECMA spec.
    static func canonicalNumber(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "null" } // JSON has no NaN/Inf
        // Delegate to the ECMA-262 §7.1.12.1 implementation.
        return ECMADouble.toString(d)
    }

    /// RFC 8785 §3.2.2.2 — JSON string serialization with minimal escapes.
    static func encodeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{0A}": out += "\\n"
            case "\u{0D}": out += "\\r"
            case "\u{09}": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.append(Character(scalar))
                }
            }
        }
        out += "\""
        return out
    }
}
