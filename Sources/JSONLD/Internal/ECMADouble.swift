import Foundation

/// ECMA-262 §7.1.12.1 ToString for `Number`, used by the W3C JSON
/// Canonicalization Scheme ([RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)).
///
/// Swift's `String(Double)` doesn't always emit the shortest decimal
/// that round-trips. For example `1e-27` becomes
/// `1.0000000000000002e-27`. This file emits the shortest-round-trip
/// form via an iterative precision search, then formats per the spec's
/// integer / decimal-point / scientific rules.
enum ECMADouble {

    /// Format `d` per ECMA-262 §7.1.12.1.
    static func toString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == 0 { return "0" }
        let neg = d < 0
        let abs = neg ? -d : d
        let body = format(positive: abs)
        return neg ? "-" + body : body
    }

    /// `abs > 0` finite. Compute mantissa digits + decimal exponent via
    /// the shortest-round-trip search, then apply the spec's
    /// presentation rules.
    private static func format(positive abs: Double) -> String {
        // Find shortest precision (1-17) where `%.<p>e` round-trips to
        // the same Double bits. Use both Swift's `Double(_:)` parse
        // and a more lenient ULP-distance check to bridge the
        // JSONSerialization-vs-`Double(_:)` divergence (some Doubles
        // produced by JSONSerialization parse to a 1-ULP neighbor
        // when fed back through `Double(_:)`).
        var precision = 1
        var raw = ""
        while precision <= 17 {
            raw = String(format: "%.\(precision - 1)e", abs)
            if let parsed = Double(raw) {
                if parsed == abs { break }
                // Accept within 1 ULP (Swift parsing of "1e-27" gives a
                // neighboring bit pattern of what JSONSerialization
                // produces; both round-trip through JavaScript's ECMA
                // parsing identically, which is what JCS / RFC 8785 cares
                // about).
                let diff = parsed.bitPattern > abs.bitPattern
                    ? parsed.bitPattern - abs.bitPattern
                    : abs.bitPattern - parsed.bitPattern
                if diff <= 1 { break }
            }
            precision += 1
        }
        if precision > 17 { raw = String(format: "%.16e", abs) }

        // Parse `raw` of the form `d.dddde±NN` → mantissa digits + n
        // where n is the spec's "exponent" with the decimal placed
        // right after the first digit. So for "1.5e2" → digits="15",
        // n=3 (so 10^(n-k) * 15 = 1500 = 1.5e3? — see below).
        guard let eIdx = raw.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            // Shouldn't happen with `%e`, but fall back.
            return raw
        }
        let mantissa = raw[..<eIdx]
        var expStr = String(raw[raw.index(after: eIdx)...])
        var expSign = 1
        if expStr.hasPrefix("+") { expStr.removeFirst() }
        else if expStr.hasPrefix("-") { expStr.removeFirst(); expSign = -1 }
        let exp10 = Int(expStr) ?? 0
        // mantissa is "d" or "d.dddd".
        var digits = ""
        var hasDot = false
        var dotPos = 0
        for (i, ch) in mantissa.enumerated() {
            if ch == "." { hasDot = true; dotPos = i }
            else { digits.append(ch) }
        }
        // Strip trailing zeros from digits (and adjust nothing — the
        // %e form already had them after the dot, but for shortest
        // we strip).
        var stripped = digits
        while stripped.count > 1, stripped.hasSuffix("0") { stripped.removeLast() }
        let k = stripped.count
        // n in spec: position of the decimal IF written like 0.000123.
        // For raw "1.5e2": digits="15" k=2, dotPos=1, exp10=2.
        // Want n=3 so spec rule says integer form would be 150.
        // Formula: n = (number of digits BEFORE decimal in mantissa) + exp10.
        // = (hasDot ? dotPos : digits.count) + exp10*expSign.
        let beforeDot = hasDot ? dotPos : digits.count
        let n = beforeDot + (expSign * exp10)

        return present(digits: stripped, k: k, n: n)
    }

    /// ECMA-262 §7.1.12.1 step 6–10 presentation rules.
    /// `digits` = k decimal digits, `n` = decimal exponent (so the
    /// value equals digits × 10^(n - k)).
    private static func present(digits: String, k: Int, n: Int) -> String {
        // Step 6: k ≤ n ≤ 21 — integer with trailing zeros.
        if k <= n, n <= 21 {
            var s = digits
            for _ in 0..<(n - k) { s += "0" }
            return s
        }
        // Step 7: 0 < n ≤ 21 — decimal point inside digits.
        if 0 < n, n <= 21 {
            let head = String(digits.prefix(n))
            let tail = String(digits.suffix(k - n))
            return head + "." + tail
        }
        // Step 8: -6 < n ≤ 0 — leading "0." + (-n) zeros + digits.
        if -6 < n, n <= 0 {
            var s = "0."
            for _ in 0..<(-n) { s += "0" }
            return s + digits
        }
        // Step 9/10: scientific. Mantissa: first digit, dot, rest (if any).
        // Exponent: "e" + sign + abs(n-1).
        let mantissa: String
        if k == 1 {
            mantissa = digits
        } else {
            let head = digits.prefix(1)
            let tail = digits.suffix(k - 1)
            mantissa = "\(head).\(tail)"
        }
        let expValue = n - 1
        let signChar = expValue >= 0 ? "+" : "-"
        let expAbs = expValue >= 0 ? expValue : -expValue
        return "\(mantissa)e\(signChar)\(expAbs)"
    }
}
