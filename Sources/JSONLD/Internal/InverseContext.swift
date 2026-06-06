import Foundation

extension JSONLD {
    /// Inverse-context table used during compaction.
    ///
    /// Implements [JSON-LD 1.1 API §8.3 Inverse Context
    /// Creation](https://www.w3.org/TR/json-ld11-api/#inverse-context-creation)
    /// — given a target IRI plus type/language/container hints, pick
    /// the best term per spec.
    struct InverseContext: Sendable {
        // entries[iri][containerSig][typeOrLang][typeKey or langKey] = term
        // containerSig: a sorted concatenation of `@container` kinds, e.g. "@list", "@set", "@language", "@type", "@id", "@index", "@graph", or "@none" when no container.
        // typeOrLang: "@type" or "@language" or "@any".
        // typeKey / langKey: the term's @type IRI (or "@id"/"@vocab"/"@none"/"@reverse"); or the language tag (lowercased) / "@null" / "@none".
        struct Entry: Sendable {
            // containerSig -> typeOrLang -> typeOrLangKey -> term
            var byContainer: [String: [String: [String: String]]] = [:]
        }

        let entries: [String: Entry]
        // Map of IRI prefix → list of terms (in shortest-then-lex order)
        // that are prefix-flagged terms with that IRI mapping. Used for
        // compact IRI generation.
        let prefixCandidates: [(iri: String, term: String)]

        init(_ ctx: ActiveContext) {
            var entries: [String: Entry] = [:]
            let defaultLanguage = (ctx.defaultLanguage ?? "@none").lowercased()
            let defaultDirection: String? = {
                switch ctx.defaultBaseDirection {
                case .ltr: return "ltr"
                case .rtl: return "rtl"
                default: return nil
                }
            }()

            // Sort terms by shortest-first then lexicographic, so longer
            // terms only fill in slots not already taken (per §8.3 step 3).
            let sortedTerms = ctx.termDefinitions.keys.sorted { a, b in
                if a.count != b.count { return a.count < b.count }
                return a < b
            }

            for term in sortedTerms {
                guard let def = ctx.termDefinitions[term] else { continue }
                if def.nullMapping { continue }
                guard let iri = def.iriMapping else { continue }

                // Container signature: empty string if no container.
                let containerSig: String = {
                    let kinds = def.containerMapping.map { $0.rawValue }.sorted()
                    return kinds.isEmpty ? "@none" : kinds.joined()
                }()

                var entry = entries[iri] ?? Entry()
                var cmap = entry.byContainer[containerSig] ?? [:]

                func add(_ category: String, key: String) {
                    var slot = cmap[category] ?? [:]
                    if slot[key] == nil { slot[key] = term }
                    cmap[category] = slot
                }

                // @any: every term registers under @none for "match anything"
                add("@any", key: "@none")

                if def.reverseProperty {
                    add("@type", key: "@reverse")
                } else if def.typeMapping == "@none" {
                    add("@any", key: "@none")
                    add("@language", key: "@none")
                    add("@type", key: "@none")
                } else if let t = def.typeMapping {
                    add("@type", key: t)
                } else if case .tag(let lang) = def.languageMapping,
                          let dir = Self.directionStr(def.directionMapping)
                {
                    add("@language", key: "\(lang)_\(dir)".lowercased())
                } else if case .tag(let lang) = def.languageMapping {
                    add("@language", key: lang.lowercased())
                } else if case .null = def.languageMapping,
                          let dir = Self.directionStr(def.directionMapping)
                {
                    add("@language", key: "_\(dir)")
                } else if case .null = def.languageMapping {
                    add("@language", key: "@null")
                } else if let dir = Self.directionStr(def.directionMapping) {
                    add("@language", key: "_\(dir)")
                } else if let dir = defaultDirection {
                    add("@language", key: "_\(dir)")
                    add("@language", key: "@none")
                    add("@type", key: "@none")
                } else {
                    add("@language", key: defaultLanguage)
                    add("@language", key: "@none")
                    add("@type", key: "@none")
                }

                entry.byContainer[containerSig] = cmap
                entries[iri] = entry
            }
            self.entries = entries

            // Prefix candidates: terms whose iriMapping ends in a gen-delim
            // (i.e. prefixFlag is true). Sort by shortest first then lex.
            var prefixes: [(iri: String, term: String)] = []
            for (term, def) in ctx.termDefinitions {
                if def.prefixFlag, let iri = def.iriMapping, !iri.isEmpty {
                    prefixes.append((iri, term))
                }
            }
            prefixes.sort { a, b in
                if a.term.count != b.term.count { return a.term.count < b.term.count }
                return a.term < b.term
            }
            self.prefixCandidates = prefixes
        }

        static func directionStr(_ d: TermDefinition.DirectionMapping?) -> String? {
            switch d {
            case .ltr: return "ltr"
            case .rtl: return "rtl"
            default: return nil
            }
        }

        /// IRI compaction — pick the best term for the given IRI given
        /// the value's type/language/container hints.
        ///
        /// Implements a pragmatic subset of [§8.4 IRI
        /// Compaction](https://www.w3.org/TR/json-ld11-api/#iri-compaction):
        /// term-with-matching-type wins, then term-with-matching-language,
        /// then prefix-CURIE, then vocab-relative, then absolute IRI.
        func compact(
            _ iri: String,
            activeContext ctx: ActiveContext,
            value: JSON? = nil,
            vocab: Bool = true,
            reverse: Bool = false
        ) throws(JSONLD.Error) -> String {
            // Keywords compact through their aliases (if any). The
            // alias may carry a container mapping (e.g. `type` with
            // `@container: @set`), so scan every container signature
            // — not just `@none`.
            if Keyword(rawValue: iri) != nil {
                if let entry = entries[iri] {
                    for (_, cmap) in entry.byContainer {
                        if let any = cmap["@any"], let term = any["@none"] {
                            return term
                        }
                    }
                }
                return iri
            }

            // Look up term selections — preferred over absolute or
            // compact-IRI forms when present.
            if vocab, let entry = entries[iri] {
                // Container preferences depend on value shape.
                var containers: [String] = []
                if case .object(let m) = value ?? .null,
                   m["@index"] != nil, m["@graph"] == nil
                {
                    containers += ["@index", "@index@set"]
                }
                if isGraph(value) {
                    if case .object(let m) = value, m["@index"] != nil {
                        containers += ["@graph@index", "@graph@index@set", "@index", "@index@set"]
                    }
                    if case .object(let m) = value, m["@id"] != nil {
                        containers += ["@graph@id", "@graph@id@set"]
                    }
                    containers += ["@graph", "@graph@set", "@set"]
                    if case .object(let m) = value, m["@index"] == nil {
                        containers += ["@graph@index", "@graph@index@set", "@index", "@index@set"]
                    }
                    if case .object(let m) = value, m["@id"] == nil {
                        containers += ["@graph@id", "@graph@id@set"]
                    }
                } else if case .object(let m) = value ?? .null,
                          m["@value"] == nil, m["@list"] == nil
                {
                    // Node object (not value or list).
                    containers += ["@id", "@id@set", "@type", "@set@type"]
                }

                // Pick (typeOrLanguage, preferred values).
                var typeOrLanguage = "@language"
                var typeOrLanguageValue = "@null"

                if reverse {
                    typeOrLanguage = "@type"
                    typeOrLanguageValue = "@reverse"
                    containers += ["@set"]
                    // When the value carries an @index, also try @index
                    // containers so reverse + indexed terms can match.
                    if case .object(let m) = value ?? .null, m["@index"] != nil {
                        containers += ["@index", "@index@set"]
                    }
                } else if case .object(let m) = value ?? .null, m["@list"] != nil {
                    if m["@index"] == nil { containers += ["@list"] }
                    if case .array(let arr) = m["@list"] ?? .null {
                        if arr.isEmpty {
                            typeOrLanguage = "@any"
                            typeOrLanguageValue = "@none"
                        } else {
                            var commonLang: String? = nil
                            var commonType: String? = nil
                            for item in arr {
                                var itemLang = "@none"
                                var itemType = "@none"
                                if case .object(let im) = item, im["@value"] != nil {
                                    if case .string(let d) = im["@direction"] ?? .null {
                                        let l = (im["@language"].flatMap { if case .string(let s) = $0 { return s.lowercased() } else { return nil } }) ?? ""
                                        itemLang = "\(l)_\(d)"
                                    } else if case .string(let l) = im["@language"] ?? .null {
                                        itemLang = l.lowercased()
                                    } else if case .string(let t) = im["@type"] ?? .null {
                                        itemType = t
                                    } else {
                                        itemLang = "@null"
                                    }
                                } else {
                                    itemType = "@id"
                                }
                                if commonLang == nil { commonLang = itemLang }
                                else if itemLang != commonLang!, case .object(let im) = item, im["@value"] != nil { commonLang = "@none" }
                                if commonType == nil { commonType = itemType }
                                else if itemType != commonType { commonType = "@none" }
                            }
                            let cl = commonLang ?? "@none"
                            let ct = commonType ?? "@none"
                            if ct != "@none" {
                                typeOrLanguage = "@type"
                                typeOrLanguageValue = ct
                            } else {
                                typeOrLanguageValue = cl
                            }
                        }
                    }
                } else {
                    if case .object(let m) = value ?? .null, m["@value"] != nil {
                        if case .string(let l) = m["@language"] ?? .null, m["@index"] == nil {
                            containers += ["@language", "@language@set"]
                            typeOrLanguageValue = l.lowercased()
                            if case .string(let d) = m["@direction"] ?? .null {
                                typeOrLanguageValue = "\(typeOrLanguageValue)_\(d)"
                            }
                        } else if case .string(let d) = m["@direction"] ?? .null, m["@index"] == nil {
                            typeOrLanguageValue = "_\(d)"
                        } else if case .string(let t) = m["@type"] ?? .null {
                            typeOrLanguage = "@type"
                            typeOrLanguageValue = t
                        }
                    } else if value != nil {
                        // Node object: use @id type preference
                        typeOrLanguage = "@type"
                        typeOrLanguageValue = "@id"
                    }
                    containers += ["@set"]
                }
                containers += ["@none"]

                if case .object(let m) = value ?? .null, m["@index"] == nil {
                    containers += ["@index", "@index@set"]
                }
                if case .object(let m) = value ?? .null,
                   m["@value"] != nil, m.count == 1
                {
                    containers += ["@language", "@language@set"]
                }

                // Build preference list.
                var prefs: [String] = []
                if (typeOrLanguageValue == "@id" || typeOrLanguageValue == "@reverse"),
                   case .object(let m) = value ?? .null,
                   case .string(let id) = m["@id"] ?? .null
                {
                    if typeOrLanguageValue == "@reverse" { prefs.append("@reverse") }
                    let innerTerm = try compact(id, activeContext: ctx, vocab: true)
                    if let def = ctx.termDefinitions[innerTerm],
                       def.iriMapping == id
                    {
                        prefs += ["@vocab", "@id"]
                    } else {
                        prefs += ["@id", "@vocab"]
                    }
                } else {
                    prefs.append(typeOrLanguageValue)
                    // Direction-only fallback
                    if let langDir = prefs.first(where: { $0.contains("_") }) {
                        if let underscoreIdx = langDir.firstIndex(of: "_") {
                            prefs.append("_" + String(langDir[langDir.index(after: underscoreIdx)...]))
                        }
                    }
                }
                prefs.append("@none")

                for container in containers {
                    guard let cmap = entry.byContainer[container] else { continue }
                    guard let typeOrLangMap = cmap[typeOrLanguage] else { continue }
                    for pref in prefs {
                        if let term = typeOrLangMap[pref] {
                            return term
                        }
                    }
                }
            }

            // When compacting in vocab position, vocab-relative wins
            // over a CURIE candidate per [§4.2.5 IRI Compaction step
            // 7-8](https://www.w3.org/TR/json-ld11-api/#iri-compaction):
            // the algorithm only falls to a compact-IRI form when no
            // vocab-relative form is available. (t0023 expects
            // `subdir/vocab/types/Test` over `ex:vocab/types/Test`.)
            if vocab, let vocabIRI = ctx.vocabularyMapping,
               iri.hasPrefix(vocabIRI), iri.count > vocabIRI.count
            {
                let suffix = String(iri.dropFirst(vocabIRI.count))
                if ctx.termDefinitions[suffix] == nil {
                    return suffix
                }
            }

            // Compact IRI via a prefix-flagged term. Per
            // [§5.1 IRI Compaction step 5](https://www.w3.org/TR/json-ld11-api/#iri-compaction),
            // iterate ALL prefix candidates, build a candidate CURIE for
            // each, and pick the shortest (lexicographic tie-breaking).
            // ta038 has both `site:` and `site-cd:` as prefixes, and the
            // longer `site-cd:` produces the shorter result for the
            // target IRI even though `site` is the shorter term name.
            //
            // Usability per jsonld.js: the candidate CURIE name must be
            // free, OR — when compacting a bare @id (value == nil) —
            // already aliased to the same IRI.
            var bestCURIE: String? = nil
            for (mappedIRI, term) in prefixCandidates {
                guard iri.hasPrefix(mappedIRI),
                      iri.count > mappedIRI.count
                else { continue }
                let suffix = String(iri.dropFirst(mappedIRI.count))
                let candidate = "\(term):\(suffix)"
                if let candidateDef = ctx.termDefinitions[candidate] {
                    guard value == nil, candidateDef.iriMapping == iri
                    else { continue }
                }
                if let cur = bestCURIE {
                    if candidate.count < cur.count
                       || (candidate.count == cur.count && candidate < cur)
                    {
                        bestCURIE = candidate
                    }
                } else {
                    bestCURIE = candidate
                }
            }
            if let bestCURIE { return bestCURIE }

            // Document-relative (i.e. @id case) — strip the base.
            if !vocab, let baseURL = ctx.baseIRI {
                let rel = removeBase(iri: iri, base: baseURL)
                if rel != iri {
                    return rel
                }
            }

            // §7.1 step 5.8 — IRI confused with prefix: if `iri` is
            // itself a colon-delimited absolute IRI whose prefix part
            // matches a defined term with `@prefix: true`, the
            // un-compacted IRI string LOOKS like a compact-IRI form
            // for that term but its CURIE expansion produces a
            // different absolute IRI. Reject (te002).
            //
            // Pre-condition: callers must pass absolute IRIs, not
            // unexpanded CURIEs. Framing's `@default` values are
            // IRI-expanded inside `expandFrameInner` for this reason.
            if vocab, let colonIdx = iri.firstIndex(of: ":") {
                let prefix = String(iri[..<colonIdx])
                if prefix != "_",
                   !prefix.isEmpty,
                   let prefixDef = ctx.termDefinitions[prefix],
                   let prefixIRI = prefixDef.iriMapping,
                   prefixDef.prefixFlag,
                   prefixIRI != iri
                {
                    let suffix = String(iri[iri.index(after: colonIdx)...])
                    if prefixIRI + suffix != iri {
                        throw .other(code: "IRI confused with prefix",
                                     message: "absolute IRI \(iri) collides with prefix \(prefix)")
                    }
                }
            }

            return iri
        }

        private func removeBase(iri: String, base: URL) -> String {
            return JSONLD.removeBase(iri: iri, base: base)
        }

        private func isGraph(_ value: JSON?) -> Bool {
            guard case .object(let m) = value ?? .null else { return false }
            return m["@graph"] != nil
        }
    }
}
