import Foundation

extension JSONLD {
    /// Context Processing Algorithm — [JSON-LD 1.1 API §5.1](https://www.w3.org/TR/json-ld11-api/#context-processing-algorithm).
    ///
    /// Process a `localContext` (a single context value or an array of
    /// contexts) against an `activeContext`, returning a new active
    /// context.
    ///
    /// Handles:
    /// - Array unwrapping
    /// - `@base`, `@vocab`, `@language`, `@direction` (top-level)
    /// - Term definitions via `createTermDefinition`
    /// - Remote context dereferencing via `options.documentLoader`
    /// - `@propagate` revert state
    ///
    /// Not yet implemented: `@import` (1.1), full `@protected` enforcement,
    /// `@version` upgrade.
    static func processContext(
        activeContext: ActiveContext,
        localContext: JSON,
        baseURL: URL?,
        remoteContexts: [String] = [],
        overrideProtected: Bool = false,
        propagate: Bool = true,
        validateScopedContext: Bool = true,
        options: Options
    ) async throws(JSONLD.Error) -> ActiveContext {
        var result = activeContext

        // Step 1–2: normalize to an array of contexts.
        let contexts: [JSON]
        if case .array(let items) = localContext {
            contexts = items
        } else {
            contexts = [localContext]
        }

        // §5.1 step 5.5: a type-scoped context (caller passes
        // propagate=false) propagates by default ONLY when the local
        // context itself sets `@propagate: true` — otherwise the
        // pre-activation context is stashed so the expand recursion
        // can revert when descending into nested node objects.
        // Property-scoped contexts default to propagate=true and skip
        // the revert.
        var effectivePropagate = propagate
        for ctx in contexts {
            if case .object(let map) = ctx, map["@propagate"] != nil {
                // @propagate is a 1.1-only context entry.
                if result.processingMode == .jsonLd10 {
                    throw .other(code: "invalid context entry", message: "@propagate is invalid in JSON-LD 1.0")
                }
                guard case .bool(let p) = map["@propagate"]! else {
                    throw .other(code: "invalid @propagate value", message: "@propagate must be a boolean")
                }
                effectivePropagate = p
            }
        }
        if !effectivePropagate, result.previousContext == nil {
            result.previousContext = ActiveContext.Reference(activeContext)
        }

        for context in contexts {
            switch context {
            case .null:
                // §5.1 step 5.1: a `null` context resets the active
                // context. In the presence of protected terms, this
                // is only allowed in override-protected mode (typically
                // a property-scoped context); otherwise throw
                // `invalid context nullification`.
                if !overrideProtected {
                    let hasProtected = result.termDefinitions.values.contains { $0.protected }
                    if hasProtected {
                        throw .other(code: "invalid context nullification",
                                     message: "cannot nullify a context containing protected term definitions")
                    }
                }
                // Reset to the initial active context (preserving processing
                // mode and original base IRI).
                var reset = ActiveContext(
                    processingMode: result.processingMode,
                    baseIRI: result.originalBaseIRI
                )
                reset.originalBaseIRI = result.originalBaseIRI
                result = reset

            case .string(let urlStr):
                // §5.1 step 5.2: dereference the remote context.
                guard let loader = options.documentLoader else {
                    throw .loadingRemoteContextFailed(
                        "no documentLoader configured to fetch \(urlStr)"
                    )
                }
                // Resolve relative to the current base.
                let resolvedURL: URL
                if let base = baseURL, let u = URL(string: urlStr, relativeTo: base) {
                    resolvedURL = u.absoluteURL
                } else if let u = URL(string: urlStr) {
                    resolvedURL = u
                } else {
                    throw .loadingRemoteContextFailed("invalid remote context URL: \(urlStr)")
                }
                let key = resolvedURL.absoluteString
                // Recursion guard.
                if remoteContexts.contains(key) {
                    throw .recursiveContextInclusion(key)
                }
                if remoteContexts.count + 1 > options.maxRemoteContextsLoaded {
                    throw .maxRemoteContextsExceeded
                }
                let remoteDoc: RemoteDocument
                do {
                    remoteDoc = try await loader.load(url: resolvedURL)
                } catch {
                    throw .loadingRemoteContextFailed("\(urlStr): \(error)")
                }
                guard case .object(let docMap) = remoteDoc.document,
                      let innerCtx = docMap["@context"]
                else {
                    // The loader succeeded; the document just lacks a
                    // top-level @context. That's a structural defect
                    // in the remote context, not a load failure. ter05.
                    throw .invalidRemoteContext(
                        "remote document at \(urlStr) has no @context key"
                    )
                }
                // Recurse with the loaded inner context; new baseURL is
                // the final document URL (after any redirects).
                result = try await processContext(
                    activeContext: result,
                    localContext: innerCtx,
                    baseURL: remoteDoc.documentURL,
                    remoteContexts: remoteContexts + [key],
                    overrideProtected: overrideProtected,
                    propagate: propagate,
                    validateScopedContext: validateScopedContext,
                    options: options
                )

            case .object(var map):
                // §4.1.7: `@import` — dereference the named context,
                // merge imported keys as the base layer, surrounding
                // keys (except @import) override.
                if let importValue = map["@import"] {
                    // @import is 1.1-only. In 1.0 processing mode it is
                    // an unexpected context entry.
                    if result.processingMode == .jsonLd10 {
                        throw .other(code: "invalid context entry", message: "@import is invalid in JSON-LD 1.0")
                    }
                    guard case .string(let importURL) = importValue else {
                        throw .other(code: "invalid @import value", message: "@import value must be a string")
                    }
                    guard let loader = options.documentLoader else {
                        throw .loadingRemoteContextFailed(
                            "no documentLoader configured to fetch @import \(importURL)"
                        )
                    }
                    let resolvedURL: URL
                    if let base = baseURL, let u = URL(string: importURL, relativeTo: base) {
                        resolvedURL = u.absoluteURL
                    } else if let u = URL(string: importURL) {
                        resolvedURL = u
                    } else {
                        throw .loadingRemoteContextFailed("invalid @import URL: \(importURL)")
                    }
                    let imported: RemoteDocument
                    do {
                        imported = try await loader.load(url: resolvedURL)
                    } catch {
                        throw .loadingRemoteContextFailed("@import \(importURL): \(error)")
                    }
                    guard case .object(let importedDoc) = imported.document,
                          case .object(let importedCtx) = importedDoc["@context"] ?? .null
                    else {
                        throw .other(code: "invalid remote context", message: "@import target must have an object @context")
                    }
                    // §4.1.7 imported context MUST NOT carry @import.
                    if importedCtx["@import"] != nil {
                        throw .other(code: "invalid context entry", message: "imported context contains nested @import")
                    }
                    // Merge: imported is the base, surrounding map overrides.
                    var merged = importedCtx
                    for (k, v) in map where k != "@import" {
                        merged[k] = v
                    }
                    map = merged
                }
                let preContext = result
                try await processContextObject(
                    map: map,
                    result: &result,
                    baseURL: baseURL,
                    preContext: preContext,
                    overrideProtected: overrideProtected,
                    options: options
                )

            default:
                throw .invalidLocalContext("expected null, string, or object")
            }
        }

        return result
    }

    private static func processContextObject(
        map: [String: JSON],
        result: inout ActiveContext,
        baseURL: URL?,
        preContext: ActiveContext,
        overrideProtected: Bool = false,
        options: Options
    ) async throws(JSONLD.Error) {
        // §4.1.6: `@version`. The only legal value is `1.1` (a double
        // or int). Any other value is `invalid @version value`. Once
        // `@version: 1.1` appears in a context, the processing mode
        // must be JSON-LD 1.1; if a caller explicitly set 1.0 mode
        // and the context demands 1.1, throw `processing mode
        // conflict`.
        if let versionValue = map["@version"] {
            // Only literal `1.1` accepted; ints and other doubles
            // (including `1.0` which parses as int(1) per the JSON
            // fixture loader's integer-detection rule) are rejected.
            let versionOK: Bool = {
                if case .double(let d) = versionValue, d == 1.1 { return true }
                return false
            }()
            if !versionOK {
                throw .other(code: "invalid @version value",
                             message: "@version value must be 1.1")
            }
            if result.processingMode == .jsonLd10 {
                throw .processingModeConflict(
                    "@version: 1.1 cannot be used in JSON-LD 1.0 processing mode"
                )
            }
        }

        // Top-level context keywords.
        if let baseValue = map["@base"] {
            // Resolve subsequent @base values against the current
            // context base, not the original document base — so that
            // multiple contexts in an array can chain.
            let resolveBase = result.baseIRI ?? baseURL
            switch baseValue {
            case .null:
                result.baseIRI = nil
            case .string(let s):
                // Empty @base is a no-op; the running base IRI stays.
                if s.isEmpty {
                    if result.baseIRI == nil { result.baseIRI = baseURL }
                } else if containsInvalidIRIChars(s) {
                    // Pre-check before Foundation's URL parser silently
                    // percent-encodes `<>{}` etc. Leaving baseIRI nil
                    // here causes downstream IRI resolution to use the
                    // raw string verbatim, which fails the toRDF WF
                    // filter on `<>` (tli12).
                    result.baseIRI = nil
                } else if let base = resolveBase,
                          let url = URL(string: resolveAgainstBase(s, base: base))
                {
                    result.baseIRI = url.absoluteURL
                } else if let url = URL(string: s, relativeTo: resolveBase) {
                    result.baseIRI = url.absoluteURL
                } else {
                    throw .other(code: "invalid base IRI", message: "invalid @base: \(s)")
                }
            default:
                throw .other(code: "invalid base IRI", message: "@base must be a string or null")
            }
        }

        if let vocabValue = map["@vocab"] {
            switch vocabValue {
            case .null:
                result.vocabularyMapping = nil
            case .string(let s):
                // IRI-expand the @vocab value. Per §5.2 step 10, a
                // relative (or empty) @vocab in 1.1 resolves against
                // the document base IRI.
                var defs: [String: Bool] = [:]
                let expanded: String?
                do {
                    expanded = try await expandIRI(
                        value: s, activeContext: &result,
                        documentRelative: true,
                        vocab: true, localContext: map,
                        defined: &defs, options: options
                    )
                } catch {
                    expanded = nil
                }
                if let expanded {
                    result.vocabularyMapping = expanded
                } else {
                    result.vocabularyMapping = s
                }
            default:
                throw .other(code: "invalid vocab mapping",
                             message: "@vocab must be a string or null")
            }
        }

        if let langValue = map["@language"] {
            switch langValue {
            case .null:
                result.defaultLanguage = nil
            case .string(let s):
                result.defaultLanguage = s.lowercased()
            default:
                throw .other(code: "invalid default language",
                             message: "@language must be a string or null")
            }
        }

        if let dirValue = map["@direction"] {
            switch dirValue {
            case .null:
                result.defaultBaseDirection = nil
            case .string("ltr"):
                result.defaultBaseDirection = .ltr
            case .string("rtl"):
                result.defaultBaseDirection = .rtl
            default:
                throw .other(code: "invalid base direction",
                             message: "@direction must be \"ltr\", \"rtl\", or null")
            }
        }

        // Term definitions. Skip the context-level keywords (already
        // handled above) and any key that *looks* like a JSON-LD
        // keyword (matches `@<letters>`). Other `@`-prefixed keys
        // (e.g. `@`, `@foo.bar`) ARE valid term names and get
        // processed normally.
        // (`@propagate` handling is hoisted into `processContext` so a
        // type-scoped context's explicit `@propagate: true` can
        // override the type-scoping's default propagate=false.)

        let contextLevelKeywords: Set<String> = [
            "@base", "@vocab", "@language", "@direction",
            "@version", "@import", "@propagate", "@protected",
        ]
        // Context-level `@protected: true` makes every term definition
        // in this context protected by default — per
        // [§4.1.11](https://www.w3.org/TR/json-ld11/#protected-term-definitions).
        // Per-term `@protected` overrides this default.
        let protectedDefault: Bool = {
            if case .bool(let b) = map["@protected"] ?? .null { return b }
            return false
        }()
        var defined: [String: Bool] = [:]
        for key in map.keys {
            if contextLevelKeywords.contains(key) { continue }
            // Per [JSON-LD 1.1 §4.1.3](https://www.w3.org/TR/json-ld11/#aliasing-keywords),
            // `@type` and `@id` can carry their own term definition
            // (used to attach `@container: @set` to `@type`, or to
            // alias `@type` to a different term). Other REAL keywords
            // throw `keyword redefinition`; other `@`-prefixed names
            // (e.g. `@foo`) are reserved and silently skipped.
            if hasKeywordForm(key), key != "@type", key != "@id" {
                if Keyword(rawValue: key) != nil {
                    throw .other(code: "keyword redefinition",
                                 message: "cannot redefine keyword \(key)")
                }
                continue
            }
            try await createTermDefinition(
                term: key,
                activeContext: &result,
                localContext: map,
                defined: &defined,
                protectedDefault: protectedDefault,
                overrideProtected: overrideProtected,
                options: options
            )
        }
    }

    /// Create Term Definition — [JSON-LD 1.1 API §5.2](https://www.w3.org/TR/json-ld11-api/#create-term-definition).
    ///
    /// **Status — Phase 2 stub.** Handles the most common shapes
    /// (string value mapping to an IRI; `{"@id": "..."}` form). Many
    /// spec edge cases are NOT yet implemented:
    /// - `@reverse` properties
    /// - `@container` with multi-value sets
    /// - `@nest`
    /// - `@protected` enforcement
    /// - `@prefix` opt-in
    /// - Scoped `@context`
    /// - Language/direction mappings
    /// - Type mapping resolution against `@vocab`
    static func createTermDefinition(
        term: String,
        activeContext: inout ActiveContext,
        localContext: [String: JSON],
        defined: inout [String: Bool],
        protectedDefault: Bool = false,
        overrideProtected: Bool = false,
        options: Options
    ) async throws(JSONLD.Error) {
        // §5.2 step 2: the term name must be a non-empty string. The
        // empty string is invalid.
        if term.isEmpty {
            throw .invalidTermDefinition("term name must be a non-empty string")
        }
        // Names that look like relative IRIs (start with `./` or
        // `../`) are rejected. For STRING term values the spec code
        // is `invalid IRI mapping` (ter48); for OBJECT term values
        // it's `invalid term definition` (ter49 — the @prefix check
        // inside an object form takes precedence).
        if term.hasPrefix("./") || term.hasPrefix("../") {
            if case .object = localContext[term] ?? .null {
                throw .invalidTermDefinition("term name \(term) looks like a relative IRI")
            }
            throw .invalidIRIMapping("term name \(term) looks like a relative IRI")
        }
        if let state = defined[term] {
            if state { return }
            throw .cyclicIRIMapping(term)
        }
        defined[term] = false

        guard let value = localContext[term] else {
            defined[term] = true
            return
        }

        // §5.2 step 3: keyword redefinition. Only `@type` and `@id`
        // may be aliased; doing so requires JSON-LD 1.1 AND the
        // definition must be `{@container: @set}` or
        // `{@id: @<keyword>, @container: @set}`. Other keyword term
        // names throw `keyword redefinition`.
        if Keyword(rawValue: term) != nil {
            // §5.2 step 5: if the existing @type/@id alias was
            // protected, any redefinition (even one that would fail
            // the keyword-redefinition shape check) is a protected
            // term redefinition, not a keyword redefinition. Surface
            // the more specific code first.
            if (term == "@type" || term == "@id"),
               let prior = activeContext.termDefinitions[term],
               prior.protected, !overrideProtected
            {
                throw .other(code: "protected term redefinition",
                             message: "protected alias of \(term) cannot be redefined")
            }
            if term != "@type" && term != "@id" {
                throw .other(code: "keyword redefinition",
                             message: "cannot redefine keyword \(term)")
            }
            if activeContext.processingMode == .jsonLd10 {
                throw .other(code: "keyword redefinition",
                             message: "aliasing keyword \(term) requires JSON-LD 1.1")
            }
            // Validate the @type / @id alias shape: must be an object
            // whose only keys are @container (= @set) and optionally
            // @id (only @type aliasing allows @id), @protected.
            guard case .object(let m) = value else {
                throw .other(code: "keyword redefinition",
                             message: "\(term) alias definition must be an object")
            }
            let allowed: Set<String> = term == "@type"
                ? ["@container", "@protected", "@id"]
                : ["@container", "@protected"]
            if !m.keys.allSatisfy({ allowed.contains($0) }) {
                throw .other(code: "keyword redefinition",
                             message: "\(term) alias definition contains disallowed key")
            }
            // @container value must be exactly @set (possibly inside
            // an array).
            let containerVal = m["@container"] ?? .null
            let containerOK: Bool = {
                if case .string("@set") = containerVal { return true }
                if case .array(let arr) = containerVal,
                   arr.count == 1,
                   case .string("@set") = arr[0] { return true }
                return false
            }()
            if !containerOK {
                throw .other(code: "keyword redefinition",
                             message: "\(term) alias must specify @container: @set")
            }
        }

        // §5.2 step 5: protected-term enforcement. If the active
        // context has an existing term definition for this term marked
        // as protected, and we're not in override-protected mode, the
        // new definition must be SAME except for `@protected` itself —
        // otherwise throw `protected term redefinition`.
        let existingDef = activeContext.termDefinitions[term]
        // Redefinition: remove any previous term def so the string-
        // value path (which IRI-expands and falls back to vocab) sees
        // the term as undefined rather than recovering the OLD
        // iri-mapping from an earlier context in a multi-context chain.
        activeContext.termDefinitions.removeValue(forKey: term)

        var def = TermDefinition()

        switch value {
        case .null:
            def.iriMapping = nil
            def.nullMapping = true

        case .string(let iri):
            // IRI-expand against the (current + local) context.
            //  - Real keywords pass through.
            //  - Strings shaped like keywords but not real ones leave
            //    the term effectively undefined so vocab/base
            //    resolution applies later (e.g. "@ignoreMe").
            //  - Otherwise IRI-expand vocab+localContext (handles
            //    aliasing chains like url→id→@id).
            if Keyword(rawValue: iri) != nil {
                def.iriMapping = iri
            } else if hasKeywordForm(iri) {
                def.iriMapping = nil
            } else {
                var defs = defined
                if let expanded = try await expandIRI(
                    value: iri,
                    activeContext: &activeContext,
                    vocab: true,
                    localContext: localContext,
                    defined: &defs,
                    options: options
                ) {
                    def.iriMapping = expanded
                } else {
                    def.iriMapping = iri
                }
            }
            // Auto-prefix: per §5.2 step 17, a term whose value is a
            // simple string mapping to an IRI ending in a gen-delim
            // character is considered a prefix.
            if let last = def.iriMapping?.last, "://?#[]@".contains(last) {
                def.prefixFlag = true
            }

        case .object(let map):
            // §5.2 step 13.1: validate `@id` value type. Must be a
            // string or null; anything else is `invalid IRI mapping`.
            if let idVal = map["@id"], idVal != .null {
                if case .string = idVal {} else {
                    throw .invalidIRIMapping("@id on term \(term) must be a string or null")
                }
            }
            // Detect explicit @id: null
            if case .some(.null) = map["@id"] {
                def.nullMapping = true
            }
            if case .string(let s) = map["@id"] ?? .null {
                // IRI-expand the @id value against the local context so
                // compact-IRI references (e.g. "vocab:label" when "vocab"
                // is defined in the same context) resolve to their full
                // IRI form. Keywords pass through unchanged.
                if Keyword(rawValue: s) != nil {
                    // §4.1.3: most keywords may be aliased; @context
                    // is the notable exception (its presence drives
                    // context processing itself).
                    if s == "@context" {
                        throw .other(code: "invalid keyword alias",
                                     message: "term \(term) cannot alias keyword @context")
                    }
                    def.iriMapping = s
                } else if hasKeywordForm(s) {
                    // @id matches keyword form but isn't a real
                    // keyword — leave the term effectively undefined
                    // (iriMapping nil, no nullMapping flag) so the
                    // outer key lookup falls through to vocab/base
                    // resolution.
                    def.iriMapping = nil
                } else {
                    var defs = defined
                    // vocab:true so a relative term like "bar" against
                    // @vocab="http://example/" resolves to
                    // "http://example/bar". documentRelative:true so
                    // bare suffixes ("@", "foo") resolve against the
                    // base IRI when @vocab is absent.
                    if let expanded = try await expandIRI(
                        value: s,
                        activeContext: &activeContext,
                        documentRelative: true,
                        vocab: true,
                        localContext: localContext,
                        defined: &defs,
                        options: options
                    ) {
                        def.iriMapping = expanded
                    } else {
                        def.iriMapping = s
                    }
                }
            }
            // Expanded-form term definitions (`{"@id": …}`) only act
            // as compact-IRI prefixes when `@prefix: true` is set
            // explicitly — they don't auto-detect from the IRI's last
            // char like simple-string definitions do. See
            // [JSON-LD 1.1 §4.1.4](https://www.w3.org/TR/json-ld11/#compact-iris).
            if let prefixValue = map["@prefix"] {
                // @prefix in a term def is 1.1-only.
                if activeContext.processingMode == .jsonLd10 {
                    throw .invalidTermDefinition("@prefix on term \(term) requires processing mode 1.1")
                }
                guard case .bool(let b) = prefixValue else {
                    throw .other(code: "invalid @prefix value",
                                 message: "@prefix must be a boolean for term \(term)")
                }
                // §5.2 step 16.1: a term whose name contains `:` or `/`
                // (i.e. resembles a CURIE or IRI) MUST NOT be marked as
                // a prefix.
                if b, term.contains(":") || term.contains("/") {
                    throw .invalidTermDefinition("@prefix true is not allowed on term \(term) — name contains ':' or '/'")
                }
                // §5.2 step 16.2: a term aliasing a keyword cannot
                // also be marked as a prefix (tpr33: `foo: {@id: @type,
                // @prefix: true}`).
                if b, let iri = def.iriMapping, Keyword(rawValue: iri) != nil {
                    throw .invalidTermDefinition("@prefix true is not allowed on term \(term) aliasing keyword \(iri)")
                }
                def.prefixFlag = b
            }
            if let typeVal = map["@type"] {
                // §5.2 step 11: validate `@type` value.
                guard case .string(let t) = typeVal else {
                    throw .other(code: "invalid type mapping",
                                 message: "@type on term \(term) must be a string")
                }
                // §5.2 step 11: `@json` and `@none` as type-mapping
                // keywords require JSON-LD 1.1.
                if (t == "@json" || t == "@none"),
                   activeContext.processingMode == .jsonLd10
                {
                    throw .other(code: "invalid type mapping",
                                 message: "@type \(t) requires JSON-LD 1.1")
                }
                // ter23: raw `@type` containing a slash but no scheme
                // and no `@vocab` to resolve against is a relative IRI
                // that the base-IRI fallback would silently absolutize.
                // §5.2 step 11 calls this `invalid type mapping`. The
                // t0021 carve-out (vocab-relative @type with slashes)
                // works because `@vocab` is set there.
                if t.contains("/"), !t.contains(":"),
                   Keyword(rawValue: t) == nil,
                   activeContext.vocabularyMapping == nil
                {
                    throw .other(code: "invalid type mapping",
                                 message: "@type \(t) on term \(term) is a relative IRI with no @vocab to resolve against")
                }
                // Expand the type mapping against the *current* result
                // context so e.g. "xsd:date" resolves to the full IRI.
                var defs = defined
                let expanded: String?
                if let e = try await expandIRI(
                    value: t,
                    activeContext: &activeContext,
                    documentRelative: true,
                    vocab: true,
                    localContext: localContext,
                    defined: &defs,
                    options: options
                ) {
                    expanded = e
                } else {
                    expanded = t
                }
                // The type mapping must resolve to a keyword (`@id`,
                // `@vocab`, `@json`, `@none`) or an absolute IRI. A
                // blank-node identifier or relative IRI is invalid.
                if let exp = expanded {
                    let allowedKeywords: Set<String> = ["@id", "@vocab", "@json", "@none"]
                    if !allowedKeywords.contains(exp) {
                        if exp.hasPrefix("_:") {
                            throw .other(code: "invalid type mapping",
                                         message: "@type on term \(term) must not be a blank-node identifier")
                        }
                        // Absolute-IRI check: must contain a colon and
                        // not be relative-style. Approximate via URL
                        // and absolute-string heuristic.
                        if !exp.contains(":") {
                            throw .other(code: "invalid type mapping",
                                         message: "@type on term \(term) must be an absolute IRI")
                        }
                    }
                }
                def.typeMapping = expanded
            }
            // @container — validate value. Per [§5.2 step 22](https://www.w3.org/TR/json-ld11-api/#create-term-definition),
            // each container value must be one of the keyword set the
            // spec enumerates; in 1.0 only `@list`, `@set`, and
            // `@index` are valid.
            let oneOneOnlyContainers: Set<ContainerKind> = [.id, .type, .graph, .language]
            if let containerVal = map["@container"] {
                switch containerVal {
                case .string(let c):
                    guard let kind = ContainerKind(rawValue: c) else {
                        throw .other(code: "invalid container mapping",
                                     message: "@container value \"\(c)\" is not a valid container kind for term \(term)")
                    }
                    if activeContext.processingMode == .jsonLd10,
                       oneOneOnlyContainers.contains(kind)
                    {
                        throw .other(code: "invalid container mapping",
                                     message: "@container \"\(c)\" requires processing mode 1.1 for term \(term)")
                    }
                    def.containerMapping.insert(kind)
                case .array(let arr):
                    // @container arrays themselves require 1.1.
                    if activeContext.processingMode == .jsonLd10 {
                        throw .other(code: "invalid container mapping",
                                     message: "@container array form requires processing mode 1.1 for term \(term)")
                    }
                    for item in arr {
                        guard case .string(let s) = item else {
                            throw .other(code: "invalid container mapping",
                                         message: "@container array entries must be strings for term \(term)")
                        }
                        guard let kind = ContainerKind(rawValue: s) else {
                            throw .other(code: "invalid container mapping",
                                         message: "@container value \"\(s)\" is not a valid container kind for term \(term)")
                        }
                        def.containerMapping.insert(kind)
                    }
                    // §5.2 step 22: validate the COMBINATION. The
                    // allowed multi-element combinations are listed in
                    // the spec; @list cannot combine with anything
                    // else.
                    if def.containerMapping.contains(.list)
                        && def.containerMapping.count > 1
                    {
                        throw .other(code: "invalid container mapping",
                                     message: "@container @list cannot combine with other container kinds for term \(term)")
                    }
                default:
                    throw .other(code: "invalid container mapping",
                                 message: "@container on term \(term) must be a string or array of strings")
                }
            }
            // §5.2 step 22.7 — when a `@container: @type` term also
            // sets `@type` explicitly, the value must be `@id` or
            // `@vocab`. tm020 — bare IRI literal here is invalid.
            // Type-map terms without `@type` (tm003/tm006 etc.) stay
            // valid: the map keys themselves drive the types.
            if def.containerMapping.contains(.type),
               let t = def.typeMapping,
               t != "@id", t != "@vocab"
            {
                throw .other(code: "invalid type mapping",
                             message: "@container @type on term \(term) requires @type to be @id or @vocab")
            }
            if let langVal = map["@language"] {
                switch langVal {
                case .string(let lang):
                    def.languageMapping = .tag(lang.lowercased())
                case .null:
                    def.languageMapping = .null
                default:
                    throw .other(code: "invalid language mapping",
                                 message: "@language on term \(term) must be a string or null")
                }
            }
            if case .string(let d) = map["@direction"] ?? .null {
                if d == "ltr" { def.directionMapping = .ltr }
                else if d == "rtl" { def.directionMapping = .rtl }
            } else if case .null = map["@direction"] ?? .object([:]) {
                def.directionMapping = .null
            }
            // Store the property-scoped @context if present. We
            // capture null contexts too (they mean "reset the active
            // context for this property's value").
            if let ctxValue = map["@context"] {
                // Term-def scoped @context is 1.1-only.
                if activeContext.processingMode == .jsonLd10 {
                    throw .invalidTermDefinition("@context on term \(term) requires processing mode 1.1")
                }
                // §5.2 step 24 — validate the scoped context at
                // definition time. tc032/tc033: a structural defect
                // inside surfaces as "invalid scoped context" even if
                // the term is never used (so the activation path
                // never fires). Run a discardable processContext on
                // a snapshot active context; any error rewraps.
                do {
                    let validateCtx = activeContext
                    _ = try await processContext(
                        activeContext: validateCtx,
                        localContext: ctxValue,
                        baseURL: nil,
                        overrideProtected: true,
                        options: options
                    )
                } catch {
                    throw .other(code: "invalid scoped context",
                                 message: "scoped @context on term \(term) is invalid: \(error)")
                }
                def.localContext = ctxValue
            }
            if let idxValue = map["@index"] {
                // @index requires 1.1 processing mode AND @container
                // must include @index — §5.2 step 21
                // ([property-valued indexing](https://www.w3.org/TR/json-ld11/#property-based-data-indexing)).
                if activeContext.processingMode == .jsonLd10 {
                    throw .invalidTermDefinition("@index on term \(term) requires processing mode 1.1")
                }
                guard case .string(let idxProp) = idxValue else {
                    throw .invalidTermDefinition("@index value on term \(term) must be a string")
                }
                if !def.containerMapping.contains(.index) {
                    throw .invalidTermDefinition("@index on term \(term) requires @container including @index")
                }
                // Property-valued index target cannot be a keyword
                // (tpi03: `@index: "@index"` rejected).
                if Keyword(rawValue: idxProp) != nil {
                    throw .invalidTermDefinition("@index property name on term \(term) cannot be a keyword: \(idxProp)")
                }
                def.indexMapping = idxProp
            }
            if let nestValRaw = map["@nest"] {
                // @nest in a term def is 1.1-only.
                if activeContext.processingMode == .jsonLd10 {
                    throw .invalidTermDefinition("@nest on term \(term) requires processing mode 1.1")
                }
                guard case .string(let nestVal) = nestValRaw else {
                    throw .other(code: "invalid @nest value",
                                 message: "@nest in term def must be a string")
                }
                // §5.2 step 18: the only allowed @nest value is the
                // keyword `@nest` itself or a term that aliases it.
                // Other keyword-form strings (e.g. `@id`) are invalid.
                if Keyword(rawValue: nestVal) != nil, nestVal != "@nest" {
                    throw .other(code: "invalid @nest value",
                                 message: "@nest on term \(term) cannot be \(nestVal)")
                }
                // Non-keyword @nest values must resolve to a term whose
                // IRI mapping is the keyword `@nest`. ten01: the value
                // names a term that isn't defined anywhere.
                if nestVal != "@nest" {
                    var nestDef = activeContext.termDefinitions[nestVal]
                    if nestDef == nil, localContext[nestVal] != nil {
                        try await createTermDefinition(
                            term: nestVal,
                            activeContext: &activeContext,
                            localContext: localContext,
                            defined: &defined,
                            options: options
                        )
                        nestDef = activeContext.termDefinitions[nestVal]
                    }
                    if nestDef?.iriMapping != "@nest" {
                        throw .other(code: "invalid @nest value",
                                     message: "@nest on term \(term) names \(nestVal), which does not alias @nest")
                    }
                }
                def.nestValue = nestVal
            }
            if let revVal = map["@reverse"], case .string = revVal {
                // OK — string @reverse handled below
            } else if map["@reverse"] != nil {
                // §5.2 step 13.1: @reverse on a term def must be a
                // string. Booleans, objects, arrays, numbers, and null
                // are rejected.
                throw .invalidIRIMapping("@reverse on term \(term) must be a string")
            }
            // §5.2 step 13: a term def with @reverse cannot also carry
            // @id, @nest. Its @container is restricted to @set or
            // @index. Violations throw `invalid reverse property`.
            if map["@reverse"] != nil {
                if map["@id"] != nil {
                    throw .invalidReverseProperty("term \(term) cannot have both @reverse and @id")
                }
                if map["@nest"] != nil {
                    throw .invalidReverseProperty("term \(term) with @reverse cannot have @nest")
                }
                let allowedReverseContainers: Set<ContainerKind> = [.set, .index]
                if case .string(let c) = map["@container"] ?? .null,
                   let kind = ContainerKind(rawValue: c),
                   !allowedReverseContainers.contains(kind)
                {
                    throw .invalidReverseProperty("term \(term) with @reverse cannot have @container: \(c)")
                }
                if case .array(let arr) = map["@container"] ?? .null {
                    for item in arr {
                        if case .string(let s) = item,
                           let kind = ContainerKind(rawValue: s),
                           !allowedReverseContainers.contains(kind)
                        {
                            throw .invalidReverseProperty("term \(term) with @reverse cannot have @container: \(s)")
                        }
                    }
                }
            }
            if case .string(let r) = map["@reverse"] ?? .null {
                // Vocab-resolve the reverse value just like @id.
                // Keyword-form strings that aren't real keywords leave
                // the term undefined so vocab resolution applies.
                if Keyword(rawValue: r) != nil {
                    def.iriMapping = r
                    def.reverseProperty = true
                } else if hasKeywordForm(r) {
                    def.iriMapping = nil
                    // Not a reverse property — fall through to vocab.
                } else {
                    var defs = defined
                    if let expanded = try await expandIRI(
                        value: r, activeContext: &activeContext,
                        vocab: true, localContext: localContext,
                        defined: &defs, options: options
                    ) {
                        def.iriMapping = expanded
                    } else {
                        def.iriMapping = r
                    }
                    // §5.2 step 13.4: the resolved IRI must be an
                    // absolute IRI or blank-node identifier.
                    if let resolved = def.iriMapping,
                       !resolved.hasPrefix("_:"),
                       !resolved.contains(":")
                    {
                        throw .invalidIRIMapping("@reverse on term \(term) must resolve to an absolute IRI: \(resolved)")
                    }
                    def.reverseProperty = true
                }
            }

            // §5.2 step 14-19: if the term def has no @id and no
            // @reverse, fall back to deriving the IRI mapping from the
            // term itself: as a compact IRI (prefix:suffix), a relative
            // IRI against the vocab mapping, or — for terms containing
            // a slash — as a relative IRI against the vocab mapping.
            // This is needed for type-scoped contexts where the term
            // (e.g. "B") gets defined with just a @context attached, and
            // later @type expansion needs the term's iri-mapping to
            // resolve against the vocab at DEFINITION time, not at use
            // time (the vocab may change between the two via an inline
            // @context).
            if def.iriMapping == nil, !def.nullMapping,
               map["@id"] == nil, map["@reverse"] == nil
            {
                if let colonIdx = term.firstIndex(of: ":"),
                   colonIdx != term.startIndex,
                   colonIdx != term.index(before: term.endIndex)
                {
                    let prefix = String(term[..<colonIdx])
                    let suffix = String(term[term.index(after: colonIdx)...])
                    if prefix == "_" || suffix.hasPrefix("//") {
                        def.iriMapping = term
                    } else {
                        // §5.2 step 14: prefix-defined compact IRI in term
                        // name → concatenate prefix's iri-mapping + suffix.
                        // This is regardless of the prefix's @prefix flag
                        // (the @prefix flag gates use-time compact-IRI
                        // expansion, but definition-time concatenation is
                        // unconditional). Force a forward-reference define
                        // of the prefix first if needed.
                        if defined[prefix] == nil, localContext[prefix] != nil {
                            try await createTermDefinition(
                                term: prefix,
                                activeContext: &activeContext,
                                localContext: localContext,
                                defined: &defined,
                                options: options
                            )
                        }
                        if let prefixDef = activeContext.termDefinitions[prefix],
                           let prefixIRI = prefixDef.iriMapping
                        {
                            def.iriMapping = prefixIRI + suffix
                        } else {
                            var defs = defined
                            if let expanded = try await expandIRI(
                                value: term,
                                activeContext: &activeContext,
                                vocab: true,
                                localContext: localContext,
                                defined: &defs,
                                options: options
                            ) {
                                def.iriMapping = expanded
                            } else {
                                def.iriMapping = term
                            }
                        }
                    }
                } else if term.contains("/") {
                    var defs = defined
                    if let expanded = try await expandIRI(
                        value: term,
                        activeContext: &activeContext,
                        documentRelative: true,
                        vocab: true,
                        localContext: localContext,
                        defined: &defs,
                        options: options
                    ) {
                        def.iriMapping = expanded
                    } else {
                        def.iriMapping = term
                    }
                } else if term == "@type" {
                    def.iriMapping = "@type"
                } else if let vocab = activeContext.vocabularyMapping {
                    def.iriMapping = vocab + term
                }
                // Otherwise leave iriMapping nil — vocab/base fallback
                // happens at use time in expandIRI.
            }

        default:
            throw .invalidTermDefinition("term \(term): unsupported value shape")
        }

        // §5.2 step 19: when a term def has no IRI mapping after the
        // @id/@reverse/vocab-fallback chain, the term is genuinely
        // unresolvable — throw `invalid IRI mapping`. Carve out the
        // case where the input was a STRING keyword-form (e.g.
        // `term: "@ignoreMe"`), which spec drops silently per tpr36–39
        // / t0120. For OBJECT-form term defs without `@id`/`@reverse`,
        // there's no keyword-form carve-out to preserve.
        if def.iriMapping == nil, !def.nullMapping, !def.reverseProperty,
           case .object(let m) = value, m["@id"] == nil, m["@reverse"] == nil
        {
            throw .invalidIRIMapping("term \(term) has no IRI mapping")
        }

        // Note: "colliding keywords" (two terms aliasing same keyword)
        // is allowed in spec §4.1.3 — multiple positive tests
        // (t0114/te114 multiple aliases of @type, t0051/te051 keyword
        // aliases, etc.) depend on this. No throw added here.

        // §5.2 step 5 — finalize `@protected`. A term-level
        // `@protected: true/false` overrides the context-level default.
        // Retain protection on redefinition: if the existing def was
        // protected and the new map doesn't explicitly say otherwise,
        // the redefined term stays protected (tpr42). Without this,
        // an identical redefinition in an unprotected context would
        // silently drop protection, allowing a later redefinition with
        // a different IRI mapping to slip through.
        let termProtected: Bool = {
            if case .object(let m) = value,
               case .bool(let b) = m["@protected"] ?? .null
            { return b }
            if let existingDef, existingDef.protected { return true }
            return protectedDefault
        }()
        def.protected = termProtected

        // If an existing protected def is being redefined, the new def
        // must be SAME as the existing one (ignoring `@protected`
        // itself), per §5.2 step 5. Otherwise throw.
        if let existingDef, existingDef.protected, !overrideProtected {
            var existingForCompare = existingDef
            existingForCompare.protected = def.protected
            if existingForCompare != def {
                throw .other(code: "protected term redefinition",
                             message: "term \(term) is protected and cannot be redefined")
            }
        }

        // §5.2 steps 17 + 22 — an IRI-shaped term name's IRI mapping
        // must equal the natural expansion of the name itself.
        //   - ter43: absolute-IRI term name aliased to a keyword.
        //   - ter44: compact-IRI term name whose @id maps elsewhere.
        // 1.1-only — the 1.0 spec doesn't enforce this (t0026 covers
        // the legacy 1.0 shape).
        if activeContext.processingMode == .jsonLd11,
           let mapping = def.iriMapping,
           !def.nullMapping,
           Keyword(rawValue: term) == nil,
           let colonIdx = term.firstIndex(of: ":"),
           colonIdx != term.startIndex,
           colonIdx != term.index(before: term.endIndex)
        {
            let prefix = String(term[..<colonIdx])
            let suffix = String(term[term.index(after: colonIdx)...])

            if suffix.hasPrefix("//") {
                // Absolute-IRI term name (`scheme://…`). The IRI
                // mapping must equal the term — a keyword alias here
                // is ter43.
                if mapping != term {
                    throw .invalidIRIMapping(
                        "term \(term) is an absolute IRI but @id (\(mapping)) differs")
                }
            } else if prefix != "_",
                      let prefixDef = activeContext.termDefinitions[prefix],
                      let prefixIRI = prefixDef.iriMapping
            {
                // Compact-IRI-shaped term name with a known prefix in
                // the active context — IRI mapping must match
                // `prefix:suffix` expansion. ter44.
                let expected = prefixIRI + suffix
                if mapping != expected {
                    throw .invalidIRIMapping(
                        "term \(term) compact-IRI form expands to \(expected); @id (\(mapping)) differs")
                }
            }
        }

        activeContext.termDefinitions[term] = def
        defined[term] = true
    }

    /// True when `s` carries IRI-reserved characters Foundation would
    /// silently percent-encode (closes tli12: `@base: "http://invalid/<>/"`
    /// shouldn't slip past the WF filter after URL parsing).
    private static func containsInvalidIRIChars(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if scalar.value < 0x20 { return true }
            switch scalar {
            case " ", "\"", "<", ">", "{", "}", "|", "\\", "^", "`":
                return true
            default:
                continue
            }
        }
        return false
    }
}
