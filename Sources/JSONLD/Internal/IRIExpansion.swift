import Foundation

extension JSONLD {
    /// Expand a value into an absolute IRI, blank-node identifier, or
    /// keyword, per [JSON-LD 1.1 API §5.3 "IRI Expansion"](https://www.w3.org/TR/json-ld11-api/#iri-expansion).
    ///
    /// Parameters mirror the spec algorithm:
    /// - `value`: the value to expand (typically a term, compact IRI,
    ///   absolute IRI, blank-node id, or keyword).
    /// - `documentRelative`: resolve relative IRIs against the active
    ///   context's base IRI.
    /// - `vocab`: resolve against the active context's vocabulary
    ///   mapping (i.e. for property positions, not value positions).
    /// - `localContext`/`defined`: passed in when called during context
    ///   processing so we can recursively create term definitions for
    ///   forward-referenced terms.
    ///
    /// Returns `nil` only when `value` is `nil` or a string that
    /// matches a keyword form but isn't an actual keyword (the spec
    /// requires us to silently drop such strings).
    static func expandIRI(
        value: String?,
        activeContext: inout ActiveContext,
        documentRelative: Bool = false,
        vocab: Bool = false,
        localContext: [String: JSON]? = nil,
        defined: inout [String: Bool],
        options: Options
    ) async throws(JSONLD.Error) -> String? {
        // §5.3 step 1: null → null
        guard let value else { return nil }

        // §5.3 step 2: actual keyword → return as-is
        if Keyword(rawValue: value) != nil {
            return value
        }

        // §5.3 step 3: matches keyword form but isn't a real keyword → drop
        if hasKeywordForm(value) {
            return nil
        }

        // §5.3 step 4: forward-reference — if value is in localContext
        // but its term definition hasn't been *started* yet
        // (defined[value] == nil), recursively create it. We skip the
        // recursion when defined[value] == false (in progress) to
        // avoid cyclic-IRI-mapping errors on self-referential @ids.
        if let localContext, localContext[value] != nil, defined[value] == nil {
            try await createTermDefinition(
                term: value,
                activeContext: &activeContext,
                localContext: localContext,
                defined: &defined,
                options: options
            )
        }

        // §5.3 step 5: term defined → use its iri-mapping. A term
        // with `nullMapping = true` (set when @id was explicitly
        // null) takes precedence — return nil so the caller drops it.
        if let termDef = activeContext.termDefinitions[value] {
            if termDef.nullMapping { return nil }
            if let mapping = termDef.iriMapping {
                if Keyword(rawValue: mapping) != nil {
                    return mapping
                }
                if vocab {
                    return mapping
                }
            }
        }

        // §5.3 step 6: compact IRI (`prefix:suffix`)
        if let colonIdx = value.firstIndex(of: ":") {
            let prefix = String(value[..<colonIdx])
            let suffix = String(value[value.index(after: colonIdx)...])

            // Blank node identifier passes through.
            if prefix == "_" { return value }

            // Already an absolute IRI (`scheme://...`) — pass through.
            if suffix.hasPrefix("//") { return value }

            // Forward reference: prefix is in the local context but
            // hasn't been *started* yet (defined[prefix] == nil).
            if let localContext, localContext[prefix] != nil {
                if defined[prefix] == nil {
                    try await createTermDefinition(
                        term: prefix,
                        activeContext: &activeContext,
                        localContext: localContext,
                        defined: &defined,
                        options: options
                    )
                } else if defined[prefix] == false {
                    // The prefix IS being defined right now — its @id
                    // resolves back to itself via this same term. That
                    // is `cyclic IRI mapping` per §5.2.
                    throw .cyclicIRIMapping(prefix)
                }
            }

            // Compact IRI: prefix is a defined term with prefix flag set.
            if let prefixDef = activeContext.termDefinitions[prefix],
               prefixDef.prefixFlag,
               let prefixIRI = prefixDef.iriMapping
            {
                return prefixIRI + suffix
            }

            // Absolute IRI with a scheme we don't recognize as a prefix.
            if isAbsoluteIRI(value) {
                return value
            }
        }

        // §5.3 step 7: vocab-relative
        if vocab, let vocabMapping = activeContext.vocabularyMapping {
            return vocabMapping + value
        }

        // §5.3 step 8: document-relative
        if documentRelative, let base = activeContext.baseIRI {
            return resolveAgainstBase(value, base: base)
        }

        // Return as-is — caller is responsible for deciding if this is
        // an error in their context.
        return value
    }

    /// True if `s` looks like an absolute IRI per RFC 3987 — has a
    /// scheme and matches the broad shape. Foundation's URL is too
    /// permissive for our needs, so this is a deliberately strict
    /// check.
    static func isAbsoluteIRI(_ s: String) -> Bool {
        guard let colonIdx = s.firstIndex(of: ":") else { return false }
        let scheme = s[..<colonIdx]
        guard !scheme.isEmpty else { return false }
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == "."
        }
    }

    /// Resolve `ref` against `base` per RFC 3986 §5.3 — including the
    /// `remove_dot_segments` step (§5.2.4) that Foundation's `URL`
    /// skips.
    static func resolveAgainstBase(_ ref: String, base: URL) -> String {
        // An absolute IRI passes through unchanged. The JSON-LD
        // IRI-resolution tests expect dot segments in absolute IRIs
        // to be preserved (e.g. `http://a/bb/ccc/./d;p?q` stored as
        // `@base`), so we MUST NOT normalize them away here.
        if isAbsoluteIRI(ref), ref.contains("://") {
            return ref
        }
        // RFC 3986 §5.3: an empty reference identifies the base
        // resource (minus its fragment). Foundation's `URL(string:)`
        // returns an empty absoluteString for an empty `ref` against
        // some bases, so we short-circuit to the base IRI string.
        if ref.isEmpty {
            var s = base.absoluteString
            if let hashIdx = s.firstIndex(of: "#") {
                s = String(s[..<hashIdx])
            }
            return s
        }
        // Bare-query / bare-fragment references replace only the
        // base's query / fragment slot. Build manually so we keep
        // any dot segments the base path carries — Foundation's
        // resolver normalizes them away, which the W3C IRI-resolution
        // tests (`t0122`–`t0125` s091/s093/s099/s133/…) explicitly
        // reject for JSON-LD.
        if ref.hasPrefix("?") || ref.hasPrefix("#") {
            var basePath = base.absoluteString
            if let hashIdx = basePath.firstIndex(of: "#") {
                basePath = String(basePath[..<hashIdx])
            }
            if ref.hasPrefix("?") {
                if let qIdx = basePath.firstIndex(of: "?") {
                    basePath = String(basePath[..<qIdx])
                }
                return basePath + ref
            }
            // ref starts with "#"
            return basePath + ref
        }
        guard let resolved = URL(string: ref, relativeTo: base) else { return ref }
        var s = resolved.absoluteString

        // Foundation preserves `./` and `../` in the path. The W3C
        // tests pin the JSON-LD-specific behavior: dot segments from
        // the base are preserved when the relative reference doesn't
        // supply a new path. Only normalize when the ref does
        // introduce path content of its own.
        let refHasPathContent = true
        if refHasPathContent, let schemeEnd = s.range(of: "://") {
            let afterScheme = s[schemeEnd.upperBound...]
            // Split out authority (everything before the next "/" or
            // end-of-string) and path.
            if let pathStart = afterScheme.firstIndex(of: "/") {
                let authority = afterScheme[..<pathStart]
                var rest = String(afterScheme[pathStart...])
                // Strip query/fragment before normalizing path.
                var query = ""
                var fragment = ""
                if let qIdx = rest.firstIndex(of: "#") {
                    fragment = String(rest[qIdx...])
                    rest = String(rest[..<qIdx])
                }
                if let qIdx = rest.firstIndex(of: "?") {
                    query = String(rest[qIdx...])
                    rest = String(rest[..<qIdx])
                }
                let normalized = removeDotSegments(rest)
                s = "\(s[..<schemeEnd.upperBound])\(authority)\(normalized)\(query)\(fragment)"
            }
        }
        return s
    }

    /// Compute the relative form of `iri` against `base` — the inverse
    /// of `resolveAgainstBase`. Ported from jsonld.js `url.removeBase`.
    static func removeBase(iri: String, base: URL) -> String {
        let baseStr = base.absoluteString
        guard let baseSchemeEnd = baseStr.range(of: "://") else { return iri }
        let baseAfterScheme = baseStr[baseSchemeEnd.upperBound...]
        // Authority = up to next `/`
        let baseAuthEnd = baseAfterScheme.firstIndex(of: "/") ?? baseAfterScheme.endIndex
        let baseRoot = String(baseStr[..<baseSchemeEnd.upperBound]) + baseAfterScheme[..<baseAuthEnd]

        guard iri.hasPrefix(baseRoot) else { return iri }

        let basePathRaw: String = {
            if baseAuthEnd != baseAfterScheme.endIndex {
                return String(baseAfterScheme[baseAuthEnd...])
            }
            return ""
        }()
        // Strip query/fragment from base path before normalization.
        let basePath: String = {
            var s = basePathRaw
            if let qIdx = s.firstIndex(of: "?") { s = String(s[..<qIdx]) }
            if let hIdx = s.firstIndex(of: "#") { s = String(s[..<hIdx]) }
            return s
        }()

        let rel = String(iri.dropFirst(baseRoot.count))
        // Split out query/fragment from rel.
        var relPath = rel
        var relQuery = ""
        var relFrag = ""
        if let hIdx = relPath.firstIndex(of: "#") {
            relFrag = String(relPath[hIdx...])
            relPath = String(relPath[..<hIdx])
        }
        if let qIdx = relPath.firstIndex(of: "?") {
            relQuery = String(relPath[qIdx...])
            relPath = String(relPath[..<qIdx])
        }
        let normBasePath = removeDotSegments(basePath)
        let normRelPath = removeDotSegments(relPath)

        var baseSegments = normBasePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var iriSegments = normRelPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        let last = (relFrag.isEmpty && relQuery.isEmpty) ? 1 : 0
        while !baseSegments.isEmpty, iriSegments.count > last {
            if baseSegments[0] != iriSegments[0] { break }
            baseSegments.removeFirst()
            iriSegments.removeFirst()
        }

        var rval = ""
        if !baseSegments.isEmpty {
            baseSegments.removeLast()
            for _ in baseSegments { rval += "../" }
        }
        rval += iriSegments.joined(separator: "/")
        rval += relQuery
        rval += relFrag
        if rval.isEmpty { rval = "./" }
        // Disambiguate keyword-look-alike + compact-IRI-look-alike
        // relative IRIs by prefixing `./` (RFC 3986 §4.2 + JSON-LD
        // §4.1.4 close: t0111). Only when the result has no leading
        // path component that already disambiguates it.
        if rval.first == "@" {
            rval = "./" + rval
        } else if let colonIdx = rval.firstIndex(of: ":"),
                  !rval[..<colonIdx].contains("/"),
                  !rval.hasPrefix("./"), !rval.hasPrefix("../")
        {
            rval = "./" + rval
        }
        return rval
    }

    /// RFC 3986 §5.2.4 `remove_dot_segments` algorithm.
    static func removeDotSegments(_ path: String) -> String {
        var input = path
        var output = ""
        while !input.isEmpty {
            if input.hasPrefix("../") {
                input.removeFirst(3)
            } else if input.hasPrefix("./") {
                input.removeFirst(2)
            } else if input.hasPrefix("/./") {
                input.removeFirst(2) // keep leading "/"
            } else if input == "/." {
                input = "/"
            } else if input.hasPrefix("/../") {
                input.removeFirst(3) // keep leading "/"
                // Remove last segment from output.
                if let lastSlash = output.lastIndex(of: "/") {
                    output = String(output[..<lastSlash])
                } else {
                    output = ""
                }
            } else if input == "/.." {
                input = "/"
                if let lastSlash = output.lastIndex(of: "/") {
                    output = String(output[..<lastSlash])
                } else {
                    output = ""
                }
            } else if input == "." || input == ".." {
                input = ""
            } else {
                // Move first segment to output.
                var i = input.startIndex
                if input.first == "/" { i = input.index(after: i) }
                while i < input.endIndex && input[i] != "/" {
                    i = input.index(after: i)
                }
                output.append(contentsOf: input[..<i])
                input = String(input[i...])
            }
        }
        return output
    }
}
