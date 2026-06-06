extension JSONLD {
    /// JSON-LD 1.1 keywords.
    ///
    /// See [JSON-LD 1.1 §1.7 Syntax Tokens and Keywords](https://www.w3.org/TR/json-ld11/#syntax-tokens-and-keywords).
    /// Keywords are reserved terms that begin with `@` followed by one or
    /// more US-ASCII letters; they cannot be aliased to other keywords.
    public enum Keyword: String, Sendable, Hashable, CaseIterable {
        case base = "@base"
        case container = "@container"
        case context = "@context"
        case direction = "@direction"
        case graph = "@graph"
        case id = "@id"
        case `import` = "@import"
        case included = "@included"
        case index = "@index"
        case json = "@json"
        case language = "@language"
        case list = "@list"
        case nest = "@nest"
        case none = "@none"
        case prefix = "@prefix"
        case propagate = "@propagate"
        case protected = "@protected"
        case reverse = "@reverse"
        case set = "@set"
        case type = "@type"
        case value = "@value"
        case version = "@version"
        case vocab = "@vocab"
        // Framing keywords ([JSON-LD 1.1 Framing](https://www.w3.org/TR/json-ld11-framing/)).
        case embed = "@embed"
        case explicit = "@explicit"
        case requireAll = "@requireAll"
        case omitDefault = "@omitDefault"
        case `default` = "@default"
        case null = "@null"
        case preserve = "@preserve"
    }
}

extension JSONLD {
    /// `true` if `value` matches the form `@<letters>` — the syntactic
    /// shape of a JSON-LD keyword, even if not one of the defined
    /// `Keyword` cases. Used during context processing to warn on (and
    /// silently drop) terms that look like reserved keywords.
    ///
    /// See [JSON-LD 1.1 API §4.2 "Algorithm Conventions"](https://www.w3.org/TR/json-ld11-api/#dfn-keyword).
    static func hasKeywordForm(_ value: String) -> Bool {
        guard value.first == "@" else { return false }
        let rest = value.dropFirst()
        guard !rest.isEmpty else { return false }
        return rest.allSatisfy { $0.isLetter && $0.isASCII }
    }
}
