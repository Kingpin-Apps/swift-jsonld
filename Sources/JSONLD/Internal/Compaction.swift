import Foundation

extension JSONLD {
    /// Compaction Algorithm — [JSON-LD 1.1 API §8](https://www.w3.org/TR/json-ld11-api/#compaction-algorithm).
    ///
    /// **Status — Phase 3 in progress.** Handles:
    /// - IRI compaction via inverse context with type / language /
    ///   container-aware term selection
    /// - Value-object compaction (collapse to scalar when type/lang
    ///   match the term's mapping)
    /// - Subject-reference compaction (`{"@id": "..."}` → string when
    ///   term has `@type: @id` or `@type: @vocab`)
    /// - `@list` and `@set` containers
    /// - `@reverse` compaction
    /// - Property-scoped + type-scoped contexts during compaction
    /// - Container-map output for `@language`, `@index`, `@id`, `@type`,
    ///   `@graph` (basic cases)
    ///
    /// Not yet implemented (the long tail):
    /// - Frame-driven shape
    /// - `@nest` recombination
    /// - All-edge @container combinations
    static func compact(
        activeContext ctx: ActiveContext,
        activeProperty: String?,
        element: JSON,
        compactArrays: Bool = true,
        ordered: Bool = false,
        inverse: InverseContext,
        options: Options
    ) async throws(JSONLD.Error) -> JSON {
        // Scalars and null pass through.
        if case .null = element { return .null }
        if case .bool = element { return element }
        if case .int = element { return element }
        if case .double = element { return element }
        if case .string = element { return element }

        // Arrays: compact each element and unwrap when appropriate.
        if case .array(let items) = element {
            var out: [JSON] = []
            for item in items {
                let compacted = try await compact(
                    activeContext: ctx, activeProperty: activeProperty,
                    element: item, compactArrays: compactArrays,
                    ordered: ordered, inverse: inverse, options: options
                )
                if case .null = compacted { continue }
                out.append(compacted)
            }
            // Unwrap single-element arrays unless the term's container
            // mapping requires an array.
            if compactArrays, out.count == 1 {
                let containers: Set<ContainerKind> = {
                    if let ap = activeProperty {
                        return ctx.termDefinitions[ap]?.containerMapping ?? []
                    }
                    return []
                }()
                if !containers.contains(.set), !containers.contains(.list),
                   activeProperty != "@graph", activeProperty != "@list",
                   activeProperty != "@set"
                {
                    return out[0]
                }
            }
            return .array(out)
        }

        guard case .object(let map) = element else { return element }

        // Type-scoped revert. If the active context carries a
        // `previousContext` from a parent's type-scoped activation,
        // pop back to the pre-activation context when entering this
        // node — unless this node is a value/list/@id-only reference,
        // which `propagate: false` carves out (mirrors `Expansion.swift`).
        // Capture the property-scoped @context for `activeProperty`
        // BEFORE the revert so a type-scoped term def supplying that
        // @context isn't lost when we pop back (`tc013`).
        var ctx = ctx
        let propLocalCtxFromTypeScope: JSON? = {
            if let ap = activeProperty,
               let prev = ctx.previousContext,
               let propDef = ctx.termDefinitions[ap],
               prev.context.termDefinitions[ap]?.localContext == nil
            {
                return propDef.localContext
            }
            return nil
        }()
        var revertedFromExplicitType = false
        if let prev = ctx.previousContext {
            let keys = map.keys
            let isValueObject = map["@value"] != nil
            let isListObject = map["@list"] != nil
            let isIDOnlyRef = (keys.count == 1 && map["@id"] != nil)
            if !isValueObject, !isListObject, !isIDOnlyRef {
                revertedFromExplicitType = ctx.previousContextFromExplicitType
                ctx = prev.context
            }
        }

        // Apply property-scoped @context for the active property —
        // either captured from the type-scoped def above or read off
        // the current (already reverted) ctx.
        let propLocalCtx: JSON? = propLocalCtxFromTypeScope ?? {
            if let ap = activeProperty { return ctx.termDefinitions[ap]?.localContext }
            return nil
        }()
        if let propLocalCtx {
            ctx = (try? await processContext(
                activeContext: ctx,
                localContext: propLocalCtx,
                baseURL: options.base,
                overrideProtected: true,
                options: options
            )) ?? ctx
        }
        var inverse = inverse
        // If we changed the context due to a property-scoped @context
        // OR a type-scoped revert, rebuild the inverse so term
        // selections see the new mappings.
        if propLocalCtx != nil {
            inverse = InverseContext(ctx)
        } else if revertedFromExplicitType {
            // tc021: untyped child below an explicit-@type-activated
            // parent needs the inverse refreshed to reflect the
            // reverted term defs. The typemap case (tm007) is gated
            // out by the flag — its inverse must stay type-scoped
            // because the typemap mechanism relies on those mappings.
            inverse = InverseContext(ctx)
        } else if let ap = activeProperty,
                  ctx.termDefinitions[ap]?.localContext != nil
        {
            inverse = InverseContext(ctx)
        }

        // Value objects: collapse / rewrite.
        if map["@value"] != nil {
            return try compactValue(map, activeProperty: activeProperty, ctx: ctx, inverse: inverse)
        }

        // Subject reference: `{"@id": "..."}`-only — compact via the
        // active property's @type mapping.
        if map.count == 1, case .string(let id) = map["@id"] ?? .null {
            let termDef = activeProperty.flatMap { ctx.termDefinitions[$0] }
            if termDef?.typeMapping == "@id" {
                return .string(try inverse.compact(id, activeContext: ctx, vocab: false))
            }
            if termDef?.typeMapping == "@vocab" {
                return .string(try inverse.compact(id, activeContext: ctx, vocab: true))
            }
        }

        // List objects: compact the @list value as an array. When the
        // active property has @list container, return raw array.
        if let listValue = map["@list"] {
            let compacted = try await compact(
                activeContext: ctx, activeProperty: activeProperty,
                element: listValue, compactArrays: false,
                ordered: ordered, inverse: inverse, options: options
            )
            if let ap = activeProperty,
               ctx.termDefinitions[ap]?.containerMapping.contains(.list) == true
            {
                if case .array = compacted { return compacted }
                return .array([compacted])
            }
            let arr: JSON
            if case .array = compacted { arr = compacted } else { arr = .array([compacted]) }
            let listAlias = try inverse.compact("@list", activeContext: ctx)
            // Preserve @index if present alongside @list.
            var out: [String: JSON] = [listAlias: arr]
            if let idx = map["@index"] {
                let idxAlias = try inverse.compact("@index", activeContext: ctx)
                out[idxAlias] = idx
            }
            return .object(out)
        }

        // Apply type-scoped contexts. §8.10 step 5: process any
        // type-scoped contexts associated with @type values.
        let preTypeCtx = ctx
        if let typeValue = map["@type"] {
            let types: [String]
            switch typeValue {
            case .string(let s): types = [s]
            case .array(let arr): types = arr.compactMap {
                if case .string(let s) = $0 { return s } else { return nil }
            }
            default: types = []
            }
            for t in types.sorted() {
                // The type values in the expanded form are full IRIs;
                // term definitions are keyed by term name. Find the
                // term whose iriMapping is this type IRI, then use its
                // localContext.
                let typeDef: TermDefinition? = {
                    if let direct = preTypeCtx.termDefinitions[t] { return direct }
                    for (_, def) in preTypeCtx.termDefinitions
                    where def.iriMapping == t {
                        return def
                    }
                    return nil
                }()
                if let typeDef, let typeCtx = typeDef.localContext {
                    // Don't swallow protected-redefinition errors; they
                    // must surface (tpr03 type-scoped trying to
                    // redefine a protected term).
                    let newCtx = try await processContext(
                        activeContext: ctx,
                        localContext: typeCtx,
                        baseURL: options.base,
                        propagate: false,
                        options: options
                    )
                    ctx = newCtx
                }
            }
            // Rebuild inverse if context changed.
            if !types.isEmpty { inverse = InverseContext(ctx) }
            // Tag the previousContext as explicit-@type-driven so child
            // recursions that revert via it know to rebuild the
            // inverse on revert (tc021). Distinguishes from typemap
            // `@container: @type` activations below, which leave the
            // flag clear (tm007 relies on the type-scoped inverse
            // surviving its revert).
            if ctx.previousContext != nil {
                ctx.previousContextFromExplicitType = true
            }
        }

        // Snapshot the pre-type-scoped context + inverse. `@type` IRIs
        // compact through the context that was active when the input
        // was authored — not through the type-scoped one that we just
        // activated, which may have nullified the very term the type
        // value references (`tc014`).
        let preTypeInverse: InverseContext = {
            if preTypeCtx.termDefinitions.count == ctx.termDefinitions.count,
               preTypeCtx.vocabularyMapping == ctx.vocabularyMapping
            { return inverse }
            return InverseContext(preTypeCtx)
        }()

        // Node object: compact each key + recurse on values.
        var result: [String: JSON] = [:]

        // Use a sorted key order for deterministic output. @type goes
        // first so its scoped context can apply to other properties.
        let sortedKeys = map.keys.sorted { a, b in
            if a == "@type", b != "@type" { return true }
            if b == "@type", a != "@type" { return false }
            return a < b
        }

        for key in sortedKeys {
            let value = map[key]!

            // @id: scalar-compact the IRI.
            if key == "@id" {
                if case .string(let s) = value {
                    let aliased = try inverse.compact("@id", activeContext: ctx)
                    result[aliased] = .string(try inverse.compact(s, activeContext: ctx, vocab: false))
                } else if case .null = value {
                    let aliased = try inverse.compact("@id", activeContext: ctx)
                    result[aliased] = .null
                }
                continue
            }
            // @type: compact each type IRI; pass through array shape
            // unless single-element collapse is appropriate.
            if key == "@type" {
                let compactedKey = try preTypeInverse.compact("@type", activeContext: preTypeCtx)
                var compactedTypes: [JSON] = []
                switch value {
                case .string(let s):
                    compactedTypes = [.string(try preTypeInverse.compact(s, activeContext: preTypeCtx, vocab: true))]
                case .array(let arr):
                    compactedTypes = []
                    for item in arr {
                        if case .string(let s) = item {
                            compactedTypes.append(.string(try preTypeInverse.compact(s, activeContext: preTypeCtx, vocab: true)))
                        }
                    }
                default:
                    compactedTypes = []
                }
                if compactedTypes.count == 1 {
                    // Single-element @type may stay as scalar UNLESS
                    // the term's container mapping requires an array.
                    // `@container: @set` only forces an array in 1.1;
                    // 1.0 mode keeps the scalar form (`t0106`).
                    let aliasDef = ctx.termDefinitions[compactedKey]
                    let forceSet = aliasDef?.containerMapping.contains(.set) == true
                        && ctx.processingMode == .jsonLd11
                    if forceSet {
                        result[compactedKey] = .array(compactedTypes)
                    } else {
                        result[compactedKey] = compactedTypes[0]
                    }
                } else if !compactedTypes.isEmpty {
                    result[compactedKey] = .array(compactedTypes)
                }
                continue
            }
            // @reverse: rewrite each inner property; if a target term
            // is itself a reverse term, hoist its value to the outer.
            if key == "@reverse" {
                guard case .object(let revMap) = value else { continue }
                var revOut: [String: JSON] = [:]
                for (ik, iv) in revMap {
                    // Per-item term selection: a forward IRI may
                    // compact to DIFFERENT non-reverse terms for
                    // different values (e.g. one with @type:@id and
                    // another with @type:@vocab).
                    let items: [JSON]
                    if case .array(let arr) = iv { items = arr }
                    else { items = [iv] }
                    // Group items by their chosen term.
                    var byTerm: [String: [JSON]] = [:]
                    var termOrder: [String] = []
                    for item in items {
                        let term = try inverse.compact(ik, activeContext: ctx, value: item, reverse: true)
                        if byTerm[term] == nil { termOrder.append(term) }
                        byTerm[term, default: []].append(item)
                    }
                    for compactedKey in termOrder {
                        let termItems = byTerm[compactedKey] ?? []
                        let termDef = ctx.termDefinitions[compactedKey]
                        let containers = termDef?.containerMapping ?? []
                        let inputValue: JSON = termItems.count == 1 ? termItems[0] : .array(termItems)
                        let compactedValue = try await compact(
                            activeContext: ctx, activeProperty: compactedKey,
                            element: inputValue, compactArrays: compactArrays,
                            ordered: ordered, inverse: inverse, options: options
                        )
                        if termDef?.reverseProperty == true {
                            // The term itself reverses — hoist to outer.
                            // Force array when the term's container
                            // mapping is `@set`.
                            var compactedValue = compactedValue
                            if containers.contains(.set),
                               !containers.contains(.index),
                               case .array = compactedValue
                            {
                                // already array; fall through
                            } else if containers.contains(.set),
                                      !containers.contains(.index)
                            {
                                compactedValue = .array([compactedValue])
                            }
                            // Apply @container @index map output. When
                            // the reverse term carries a property-valued
                            // index hint (`@index: <propertyTerm>` —
                            // [§4.6.4](https://www.w3.org/TR/json-ld11/#property-based-data-indexing)),
                            // derive the map key from that property's
                            // value on the inner node BEFORE compaction,
                            // then strip the consumed value so the
                            // round-trip is lossless. Mirrors the
                            // forward `@container: @index` handler
                            // below; needed for `t0114` / `ta038`.
                            if containers.contains(.index) {
                                if let indexProp = termDef?.indexMapping {
                                    var ctxCopy = ctx
                                    var defs: [String: Bool] = [:]
                                    let indexIRI = (try? await expandIRI(
                                        value: indexProp,
                                        activeContext: &ctxCopy,
                                        vocab: true,
                                        defined: &defs,
                                        options: options
                                    )) ?? indexProp
                                    let indexIRIResolved = indexIRI
                                    let indexTermDef = ctx.termDefinitions[indexProp]
                                    let indexTypeIRIInterprets =
                                        indexTermDef?.typeMapping == "@id"
                                        || indexTermDef?.typeMapping == "@vocab"

                                    var indexMap: [String: JSON] = [:]
                                    for item in items {
                                        guard case .object(var rawInner) = item else { continue }
                                        let rawValues: [JSON]
                                        if let bucket = rawInner[indexIRIResolved] {
                                            if case .array(let arr) = bucket { rawValues = arr }
                                            else { rawValues = [bucket] }
                                        } else { rawValues = [] }
                                        let key: String
                                        var indexValueConsumed = false
                                        if let first = rawValues.first {
                                            if case .object(let vm) = first {
                                                if case .string(let s) = vm["@value"] ?? .null {
                                                    key = s
                                                    indexValueConsumed = true
                                                } else if case .string(let id) = vm["@id"] ?? .null,
                                                          indexTypeIRIInterprets
                                                {
                                                    key = try inverse.compact(id, activeContext: ctx, vocab: true)
                                                    indexValueConsumed = true
                                                } else {
                                                    key = try inverse.compact("@none", activeContext: ctx)
                                                }
                                            } else if case .string(let s) = first {
                                                key = s
                                                indexValueConsumed = true
                                            } else {
                                                key = try inverse.compact("@none", activeContext: ctx)
                                            }
                                        } else {
                                            key = try inverse.compact("@none", activeContext: ctx)
                                        }
                                        if indexValueConsumed {
                                            if rawValues.count > 1 {
                                                rawInner[indexIRIResolved] = .array(Array(rawValues.dropFirst()))
                                            } else {
                                                rawInner.removeValue(forKey: indexIRIResolved)
                                            }
                                        }
                                        let compactedInner = try await compact(
                                            activeContext: ctx, activeProperty: nil,
                                            element: .object(rawInner), compactArrays: compactArrays,
                                            ordered: ordered, inverse: inverse, options: options
                                        )
                                        indexMap[key] = compactedInner
                                    }
                                    if case .object(let existing) = result[compactedKey] ?? .null {
                                        var merged = existing
                                        for (k, v) in indexMap { merged[k] = v }
                                        result[compactedKey] = .object(merged)
                                    } else {
                                        result[compactedKey] = .object(indexMap)
                                    }
                                    continue
                                }
                                let inner: [JSON]
                                if case .array(let arr) = compactedValue { inner = arr }
                                else { inner = [compactedValue] }
                                var indexMap: [String: JSON] = [:]
                                let indexAlias = try inverse.compact("@index", activeContext: ctx)
                                for item in inner {
                                    guard case .object(var m) = item else { continue }
                                    let idx: String? = {
                                        if case .string(let s) = m["@index"] ?? .null { return s }
                                        if case .string(let s) = m[indexAlias] ?? .null { return s }
                                        return nil
                                    }()
                                    guard let idx else { continue }
                                    m.removeValue(forKey: "@index")
                                    m.removeValue(forKey: indexAlias)
                                    indexMap[idx] = .object(m)
                                }
                                if case .object(let existing) = result[compactedKey] ?? .null {
                                    var merged = existing
                                    for (k, v) in indexMap { merged[k] = v }
                                    result[compactedKey] = .object(merged)
                                } else {
                                    result[compactedKey] = .object(indexMap)
                                }
                            } else if case .array(let existing) = result[compactedKey] ?? .null,
                                      case .array(let new) = compactedValue
                            {
                                result[compactedKey] = .array(existing + new)
                            } else {
                                result[compactedKey] = compactedValue
                            }
                        } else {
                            revOut[compactedKey] = compactedValue
                        }
                    }
                }
                if !revOut.isEmpty {
                    let revAlias = try inverse.compact("@reverse", activeContext: ctx)
                    result[revAlias] = .object(revOut)
                }
                continue
            }
            // @index, @value, @language, @direction, @included
            // get aliased keys + verbatim value recursion.
            if key == "@index" || key == "@language" || key == "@direction" {
                let aliased = try inverse.compact(key, activeContext: ctx)
                result[aliased] = value
                continue
            }
            if key == "@included" {
                let aliased = try inverse.compact(key, activeContext: ctx)
                let compactedValue = try await compact(
                    activeContext: ctx, activeProperty: aliased,
                    element: value, compactArrays: compactArrays,
                    ordered: ordered, inverse: inverse, options: options
                )
                result[aliased] = compactedValue
                continue
            }
            // @graph: compact each graph entry. The @graph alias on
            // a term with @container: @graph wraps differently —
            // handled below when iterating regular properties (this
            // branch is the top-level / non-container @graph).
            if key == "@graph" {
                let aliased = try inverse.compact("@graph", activeContext: ctx)
                var compactedValue = try await compact(
                    activeContext: ctx, activeProperty: aliased,
                    element: value, compactArrays: compactArrays,
                    ordered: ordered, inverse: inverse, options: options
                )
                // Single-element graph arrays unwrap to a bare object
                // when the enclosing node has NO `@id`/`@type` of its
                // own — a "simple graph object" (the implicit default
                // graph case in tests like t0090). Named graphs
                // (`{@id: …, @graph: […]}`) keep the array.
                let isSimpleGraphCarrier = (map["@id"] == nil)
                if isSimpleGraphCarrier, compactArrays,
                   case .array(let arr) = compactedValue,
                   arr.count == 1
                { compactedValue = arr[0] }
                result[aliased] = compactedValue
                continue
            }
            if Keyword(rawValue: key) != nil {
                // Other keywords: alias them.
                let aliased = try inverse.compact(key, activeContext: ctx)
                let compactedValue = try await compact(
                    activeContext: ctx, activeProperty: aliased,
                    element: value, compactArrays: compactArrays,
                    ordered: ordered, inverse: inverse, options: options
                )
                result[aliased] = compactedValue
                continue
            }

            // Property IRI — compact to a term and recurse.
            // We may need to iterate the expanded values to pick the
            // term per-value (different values may pick different
            // terms) but for the common case we pick once based on
            // the first value.
            let expandedValues: [JSON]
            if case .array(let arr) = value { expandedValues = arr }
            else { expandedValues = [value] }

            if expandedValues.isEmpty {
                // Empty value: still emit the property with an empty array.
                let term = try inverse.compact(key, activeContext: ctx)
                result[term] = .array([])
                continue
            }

            // Pre-pass: count how many items land in each term so we
            // can decide whether to wrap in an array. Without this,
            // a property with N expanded values that all pick the
            // SAME term gets correctly forced to array, but a property
            // whose expanded values pick DIFFERENT terms (one per
            // term) gets wrongly forced to array.
            var termCount: [String: Int] = [:]
            for expandedItem in expandedValues {
                let term = try inverse.compact(key, activeContext: ctx, value: expandedItem)
                termCount[term, default: 0] += 1
            }

            for expandedItem in expandedValues {
                let termSelectionValue = expandedItem
                let term = try inverse.compact(
                    key, activeContext: ctx, value: termSelectionValue
                )
                let termDef = ctx.termDefinitions[term]
                let containers = termDef?.containerMapping ?? []
                let multiForThisTerm = (termCount[term] ?? 0) > 1

                // @container: @language / @index / @id / @type / @graph
                // — emit as a map keyed by the container's signal.
                if containers.contains(.language),
                   case .object(let m) = expandedItem,
                   m["@value"] != nil
                {
                    var existing: [String: JSON] = [:]
                    if case .object(let e) = result[term] ?? .null {
                        existing = e
                    }
                    let langKey: String
                    if case .string(let l) = m["@language"] ?? .null {
                        langKey = l
                    } else {
                        langKey = try inverse.compact("@none", activeContext: ctx)
                    }
                    // Compact the value itself per value-compaction
                    // (which collapses to a scalar string).
                    var langValue: JSON = {
                        if case .string(let s) = m["@value"] ?? .null { return .string(s) }
                        return m["@value"] ?? .null
                    }()
                    if containers.contains(.set) {
                        langValue = .array([langValue])
                    }
                    if case .array(let arr) = existing[langKey] ?? .null {
                        if case .array(let new) = langValue {
                            existing[langKey] = .array(arr + new)
                        } else {
                            existing[langKey] = .array(arr + [langValue])
                        }
                    } else if let prior = existing[langKey] {
                        existing[langKey] = .array([prior, langValue])
                    } else {
                        existing[langKey] = langValue
                    }
                    result[term] = .object(existing)
                    continue
                }

                if containers.contains(.index), !containers.contains(.graph),
                   case .object(let m) = expandedItem
                {
                    var existing: [String: JSON] = [:]
                    if case .object(let e) = result[term] ?? .null {
                        existing = e
                    }

                    // Property-valued index ([§4.6.4](https://www.w3.org/TR/json-ld11/#property-based-data-indexing)).
                    // When the term def carries `@index: <propertyTerm>`,
                    // the map key is the value of that property on the
                    // expanded node — not `m["@index"]`. Strip the
                    // indexed property from the inner before compacting.
                    if let indexProp = termDef?.indexMapping {
                        // Resolve the indexed property term to its IRI.
                        var ctxCopy = ctx
                        var defs: [String: Bool] = [:]
                        let indexIRI = (try? await expandIRI(
                            value: indexProp,
                            activeContext: &ctxCopy,
                            vocab: true,
                            defined: &defs,
                            options: options
                        )) ?? indexProp
                        let indexIRIResolved = indexIRI

                        let rawValues: [JSON]
                        if let bucket = m[indexIRIResolved] {
                            if case .array(let arr) = bucket { rawValues = arr }
                            else { rawValues = [bucket] }
                        } else { rawValues = [] }

                        // Take the FIRST value as the map key; the rest
                        // (if any) stay on the node so the round-trip
                        // preserves them. `tpi02`/`tpi04` exercise this.
                        //
                        // A node-reference (`{@id: …}`) only yields a
                        // string key when the indexed property's term
                        // def declares `@type: @id`/`@vocab` — without
                        // that hint, an `@id` value can't be flattened
                        // to a plain string and the entry falls back
                        // to `@none` (`tpi06`).
                        let indexTermDef = ctx.termDefinitions[indexProp]
                        let indexTypeIRIInterprets =
                            indexTermDef?.typeMapping == "@id"
                            || indexTermDef?.typeMapping == "@vocab"
                        let key: String
                        var indexValueConsumed = false
                        if let first = rawValues.first {
                            if case .object(let vm) = first {
                                if case .string(let s) = vm["@value"] ?? .null {
                                    key = s
                                    indexValueConsumed = true
                                } else if case .string(let id) = vm["@id"] ?? .null,
                                          indexTypeIRIInterprets
                                {
                                    key = try inverse.compact(id, activeContext: ctx, vocab: true)
                                    indexValueConsumed = true
                                } else {
                                    key = try inverse.compact("@none", activeContext: ctx)
                                }
                            } else if case .string(let s) = first {
                                key = s
                                indexValueConsumed = true
                            } else {
                                key = try inverse.compact("@none", activeContext: ctx)
                            }
                        } else {
                            key = try inverse.compact("@none", activeContext: ctx)
                        }

                        // Build the inner. If we consumed an index
                        // value, drop the first entry (or remove the
                        // property entirely if it was the only value).
                        // When the indexed property couldn't supply a
                        // key (`@none` fallback), keep the term's
                        // `@type` mapping live so the inner compacts
                        // through it (`tpi05` collapses `{@id: …}` to
                        // a bare string). When we DID consume an
                        // index value, recurse with `activeProperty:
                        // nil` so the inner stays as a node object
                        // (`tpi01`/`tpi03`).
                        var inner = m
                        inner.removeValue(forKey: "@index")
                        if indexValueConsumed {
                            if rawValues.count > 1 {
                                inner[indexIRIResolved] = .array(Array(rawValues.dropFirst()))
                            } else {
                                inner.removeValue(forKey: indexIRIResolved)
                            }
                        }
                        let innerActiveProperty: String? = indexValueConsumed ? nil : term
                        var compactedItem = try await compact(
                            activeContext: ctx, activeProperty: innerActiveProperty,
                            element: .object(inner), compactArrays: compactArrays,
                            ordered: ordered, inverse: inverse, options: options
                        )
                        let isArr: Bool = { if case .array = compactedItem { return true }; return false }()
                        if containers.contains(.set), !isArr {
                            compactedItem = .array([compactedItem])
                        }
                        if case .array(let arr) = existing[key] ?? .null {
                            if case .array(let new) = compactedItem {
                                existing[key] = .array(arr + new)
                            } else {
                                existing[key] = .array(arr + [compactedItem])
                            }
                        } else if let prior = existing[key] {
                            existing[key] = .array([prior, compactedItem])
                        } else {
                            existing[key] = compactedItem
                        }
                        result[term] = .object(existing)
                        continue
                    }

                    let idx: String
                    if case .string(let s) = m["@index"] ?? .null {
                        idx = s
                    } else {
                        idx = try inverse.compact("@none", activeContext: ctx)
                    }
                    var inner = m
                    inner.removeValue(forKey: "@index")
                    var compactedItem = try await compact(
                        activeContext: ctx, activeProperty: term,
                        element: .object(inner), compactArrays: compactArrays,
                        ordered: ordered, inverse: inverse, options: options
                    )
                    let idxIsArr: Bool = { if case .array = compactedItem { return true }; return false }()
                    if containers.contains(.set), !idxIsArr {
                        compactedItem = .array([compactedItem])
                    }
                    if case .array(let arr) = existing[idx] ?? .null {
                        if case .array(let new) = compactedItem {
                            existing[idx] = .array(arr + new)
                        } else {
                            existing[idx] = .array(arr + [compactedItem])
                        }
                    } else if let prior = existing[idx] {
                        existing[idx] = .array([prior, compactedItem])
                    } else {
                        existing[idx] = compactedItem
                    }
                    result[term] = .object(existing)
                    continue
                }

                if containers.contains(.id), !containers.contains(.graph),
                   case .object(let m) = expandedItem
                {
                    var existing: [String: JSON] = [:]
                    if case .object(let e) = result[term] ?? .null {
                        existing = e
                    }
                    var inner = m
                    let id: String? = {
                        if case .string(let s) = m["@id"] ?? .null { return s }
                        return nil
                    }()
                    inner.removeValue(forKey: "@id")
                    var compactedItem = try await compact(
                        activeContext: ctx, activeProperty: term,
                        element: .object(inner), compactArrays: compactArrays,
                        ordered: ordered, inverse: inverse, options: options
                    )
                    let idKey: String
                    if let id {
                        idKey = try inverse.compact(id, activeContext: ctx, vocab: false)
                    } else {
                        idKey = try inverse.compact("@none", activeContext: ctx)
                    }
                    let idIsArr: Bool = { if case .array = compactedItem { return true }; return false }()
                    if containers.contains(.set), !idIsArr {
                        compactedItem = .array([compactedItem])
                    }
                    if case .array(let arr) = existing[idKey] ?? .null {
                        if case .array(let new) = compactedItem {
                            existing[idKey] = .array(arr + new)
                        } else {
                            existing[idKey] = .array(arr + [compactedItem])
                        }
                    } else if let prior = existing[idKey] {
                        existing[idKey] = .array([prior, compactedItem])
                    } else {
                        existing[idKey] = compactedItem
                    }
                    result[term] = .object(existing)
                    continue
                }

                // @container: @graph (with optional @set / @index / @id)
                // ([JSON-LD 1.1 API §8.3](https://www.w3.org/TR/json-ld11-api/#compaction-algorithm)).
                if containers.contains(.graph),
                   case .object(let m) = expandedItem,
                   let graphValue = m["@graph"]
                {
                    // §4.6.5: when @container: @graph and the value's @id
                    // is a blank node (the graph isn't referenced from
                    // elsewhere by a stable IRI), the @id can be omitted
                    // and the wrapper unwraps to the inner contents.
                    // Closes Frame tg005/tg008/tg010/tin03 and Flatten tin06.
                    let isSimpleGraph: Bool = {
                        if m.keys.allSatisfy({ $0 == "@graph" || $0 == "@index" }) {
                            return true
                        }
                        // Blank-node @id with no other surprising keys:
                        // strip the @id and treat as simple graph.
                        if case .string(let id) = m["@id"] ?? .null, id.hasPrefix("_:"),
                           m.keys.allSatisfy({ $0 == "@graph" || $0 == "@index" || $0 == "@id" })
                        {
                            return true
                        }
                        return false
                    }()
                    // Extract the inner array of node objects.
                    let innerItems: [JSON]
                    if case .array(let arr) = graphValue { innerItems = arr }
                    else { innerItems = [graphValue] }

                    // Compact each inner node under the term's
                    // property context so e.g. `value` aliases apply.
                    var compactedInner: [JSON] = []
                    for inItem in innerItems {
                        let c = try await compact(
                            activeContext: ctx, activeProperty: term,
                            element: inItem, compactArrays: compactArrays,
                            ordered: ordered, inverse: inverse, options: options
                        )
                        if case .null = c { continue }
                        compactedInner.append(c)
                    }
                    let forceArray = containers.contains(.set) || !compactArrays
                    let innerValue: JSON
                    if compactedInner.count == 1, !forceArray {
                        innerValue = compactedInner[0]
                    } else {
                        innerValue = .array(compactedInner)
                    }

                    // @container: [@graph, @id] — map keyed by @id.
                    if containers.contains(.id) {
                        var existing: [String: JSON] = [:]
                        if case .object(let e) = result[term] ?? .null {
                            existing = e
                        }
                        let key: String
                        if case .string(let s) = m["@id"] ?? .null {
                            key = try inverse.compact(s, activeContext: ctx, vocab: false)
                        } else {
                            key = try inverse.compact("@none", activeContext: ctx)
                        }
                        if let prior = existing[key] {
                            if case .array(let arr) = prior, case .array(let new) = innerValue {
                                existing[key] = .array(arr + new)
                            } else if case .array(let arr) = prior {
                                existing[key] = .array(arr + [innerValue])
                            } else if case .array(let new) = innerValue {
                                existing[key] = .array([prior] + new)
                            } else {
                                existing[key] = .array([prior, innerValue])
                            }
                        } else {
                            existing[key] = innerValue
                        }
                        result[term] = .object(existing)
                        continue
                    }

                    // @container: [@graph, @index] — map keyed by @index.
                    // Named graphs (any @id) skip the map and emit as
                    // a regular `{@graph, @id, …}` object so the @id
                    // survives in the output.
                    if containers.contains(.index), m["@id"] == nil {
                        var existing: [String: JSON] = [:]
                        if case .object(let e) = result[term] ?? .null {
                            existing = e
                        }
                        let key: String
                        if case .string(let s) = m["@index"] ?? .null { key = s }
                        else { key = try inverse.compact("@none", activeContext: ctx) }
                        if let prior = existing[key] {
                            if case .array(let arr) = prior, case .array(let new) = innerValue {
                                existing[key] = .array(arr + new)
                            } else if case .array(let arr) = prior {
                                existing[key] = .array(arr + [innerValue])
                            } else if case .array(let new) = innerValue {
                                existing[key] = .array([prior] + new)
                            } else {
                                existing[key] = .array([prior, innerValue])
                            }
                        } else {
                            existing[key] = innerValue
                        }
                        result[term] = .object(existing)
                        continue
                    }

                    // @container: @graph (with optional @set) — simple
                    // graph objects strip the @graph wrapper; named
                    // graphs (anything with @id) keep it. When more
                    // than one inner node survives, the spec wraps
                    // them in `@included` so they're carried as a
                    // single value rather than smeared into the outer
                    // property's array ([§4.6.5](https://www.w3.org/TR/json-ld11/#graph-containers)).
                    if isSimpleGraph {
                        let emitValue: JSON
                        if compactedInner.count > 1 {
                            let includedAlias = try inverse.compact("@included", activeContext: ctx)
                            emitValue = .object([includedAlias: .array(compactedInner)])
                        } else {
                            emitValue = innerValue
                        }
                        let prior = result[term]
                        let asArr: JSON
                        if case .array = emitValue { asArr = emitValue }
                        else { asArr = .array([emitValue]) }
                        if let prior {
                            if case .array(let arr) = prior, case .array(let new) = asArr {
                                result[term] = .array(arr + new)
                            } else if case .array(let arr) = prior {
                                result[term] = .array(arr + [emitValue])
                            } else if case .array(let new) = asArr {
                                result[term] = .array([prior] + new)
                            } else {
                                result[term] = .array([prior, emitValue])
                            }
                        } else if forceArray {
                            result[term] = asArr
                        } else {
                            result[term] = emitValue
                        }
                    } else {
                        // Named graph — keep the @graph wrapper.
                        var graphObj: [String: JSON] = [:]
                        let graphAlias = try inverse.compact("@graph", activeContext: ctx)
                        graphObj[graphAlias] = innerValue
                        if case .string(let idStr) = m["@id"] ?? .null {
                            let idAlias = try inverse.compact("@id", activeContext: ctx)
                            graphObj[idAlias] = .string(
                                try inverse.compact(idStr, activeContext: ctx, vocab: false)
                            )
                        }
                        if case .string(let s) = m["@index"] ?? .null {
                            let idxAlias = try inverse.compact("@index", activeContext: ctx)
                            graphObj[idxAlias] = .string(s)
                        }
                        let prior = result[term]
                        if let prior {
                            if case .array(let arr) = prior {
                                result[term] = .array(arr + [.object(graphObj)])
                            } else {
                                result[term] = .array([prior, .object(graphObj)])
                            }
                        } else {
                            result[term] = .object(graphObj)
                        }
                    }
                    continue
                }

                if containers.contains(.type),
                   case .object(let m) = expandedItem
                {
                    var existing: [String: JSON] = [:]
                    if case .object(let e) = result[term] ?? .null {
                        existing = e
                    }
                    var inner = m
                    // Take the FIRST @type, leave the rest in @type field.
                    // Capture the raw IRI alongside the compacted key so we
                    // can activate that type's scoped context for the
                    // inner compaction (jsonld.js's `compactedType` carry).
                    var rawTypeIRI: String? = nil
                    let typeKey: String
                    if case .array(let arr) = m["@type"] ?? .null, let first = arr.first,
                       case .string(let s) = first
                    {
                        if arr.count > 1 {
                            inner["@type"] = .array(Array(arr.dropFirst()))
                        } else {
                            inner.removeValue(forKey: "@type")
                        }
                        rawTypeIRI = s
                        typeKey = try inverse.compact(s, activeContext: ctx, vocab: true)
                    } else if case .string(let s) = m["@type"] ?? .null {
                        inner.removeValue(forKey: "@type")
                        rawTypeIRI = s
                        typeKey = try inverse.compact(s, activeContext: ctx, vocab: true)
                    } else {
                        typeKey = try inverse.compact("@none", activeContext: ctx)
                    }
                    // Activate the type-scoped context for the extracted
                    // type, if any, so the inner compaction picks up
                    // term aliases the type defines.
                    var typeCtx = ctx
                    var typeInverse = inverse
                    if let rawTypeIRI {
                        let typeDef: TermDefinition? = {
                            if let d = ctx.termDefinitions[rawTypeIRI] { return d }
                            for (_, d) in ctx.termDefinitions
                            where d.iriMapping == rawTypeIRI { return d }
                            return nil
                        }()
                        if let typeDef, let typeLocal = typeDef.localContext {
                            if let newCtx = try? await processContext(
                                activeContext: typeCtx,
                                localContext: typeLocal,
                                baseURL: options.base,
                                propagate: false,
                                options: options
                            ) {
                                typeCtx = newCtx
                                // Typemap-driven activation: leave the
                                // explicit-@type flag clear so the
                                // inner compact() doesn't rebuild the
                                // inverse on revert and drop the
                                // type-scoped term mappings (tm007).
                                typeCtx.previousContextFromExplicitType = false
                                typeInverse = InverseContext(typeCtx)
                            }
                        }
                    }
                    var compactedItem = try await compact(
                        activeContext: typeCtx, activeProperty: term,
                        element: .object(inner), compactArrays: compactArrays,
                        ordered: ordered, inverse: typeInverse, options: options
                    )
                    // Per [JSON-LD 1.1 §4.6.3](https://www.w3.org/TR/json-ld11/#type-maps),
                    // an `@id`-only node reference inside a `@type` map
                    // compacts to its bare IRI string — the type is
                    // already carried by the map key.
                    let idAlias = try inverse.compact("@id", activeContext: typeCtx)
                    if inner.count == 1,
                       case .string(let id) = inner["@id"] ?? .null,
                       case .object(let cm) = compactedItem,
                       cm.count == 1,
                       cm.first?.key == idAlias
                    {
                        compactedItem = .string(try inverse.compact(id, activeContext: typeCtx, vocab: false))
                    }
                    // Force array when the term has @set in its container.
                    let isArr: Bool = { if case .array = compactedItem { return true }; return false }()
                    if containers.contains(.set), !isArr {
                        compactedItem = .array([compactedItem])
                    }
                    if case .array(let arr) = existing[typeKey] ?? .null {
                        if case .array(let new) = compactedItem {
                            existing[typeKey] = .array(arr + new)
                        } else {
                            existing[typeKey] = .array(arr + [compactedItem])
                        }
                    } else if let prior = existing[typeKey] {
                        existing[typeKey] = .array([prior, compactedItem])
                    } else {
                        existing[typeKey] = compactedItem
                    }
                    result[term] = .object(existing)
                    continue
                }

                // Default: recurse, then set/accumulate.
                let compactedItem = try await compact(
                    activeContext: ctx, activeProperty: term,
                    element: expandedItem, compactArrays: compactArrays,
                    ordered: ordered, inverse: inverse, options: options
                )
                // Drop nulls that came from undefined terms — but
                // keep `null` that was an explicit `@value: null`
                // (e.g. `@type: @json` literals).
                if case .null = compactedItem {
                    let isExplicitNullValue: Bool = {
                        if case .object(let m) = expandedItem,
                           m["@value"] != nil, case .null = m["@value"]!
                        { return true }
                        return false
                    }()
                    if !isExplicitNullValue { continue }
                }
                // If existing entry, accumulate.
                let needsArray =
                    containers.contains(.set) ||
                    containers.contains(.list) ||
                    multiForThisTerm ||
                    result[term] != nil ||
                    !compactArrays
                let asArrayItem: JSON
                if case .array = compactedItem { asArrayItem = compactedItem }
                else { asArrayItem = .array([compactedItem]) }

                if let existing = result[term] {
                    if case .array(let existingArr) = existing {
                        if case .array(let new) = asArrayItem {
                            result[term] = .array(existingArr + new)
                        } else {
                            result[term] = .array(existingArr + [compactedItem])
                        }
                    } else {
                        if case .array(let new) = asArrayItem {
                            result[term] = .array([existing] + new)
                        } else {
                            result[term] = .array([existing, compactedItem])
                        }
                    }
                } else if needsArray {
                    result[term] = asArrayItem
                } else {
                    result[term] = compactedItem
                }
            }
        }

        // §8.4 step 14: @nest output. If a term's def has a @nest
        // mapping, move it under the nest container key in the result.
        var nested: [String: [String: JSON]] = [:]
        var toRemove: [String] = []
        for (key, value) in result {
            guard let def = ctx.termDefinitions[key],
                  let nestRaw = def.nestValue
            else { continue }
            // The @nest value must be either @nest itself or a term
            // that maps to @nest in the active context.
            let nestKey: String
            if nestRaw == "@nest" {
                nestKey = "@nest"
            } else if let nestDef = ctx.termDefinitions[nestRaw],
                      nestDef.iriMapping == "@nest"
            {
                nestKey = nestRaw
            } else {
                continue
            }
            nested[nestKey, default: [:]][key] = value
            toRemove.append(key)
        }
        for key in toRemove { result.removeValue(forKey: key) }
        for (nestKey, group) in nested {
            if case .object(let existing) = result[nestKey] ?? .null {
                var merged = existing
                for (k, v) in group { merged[k] = v }
                result[nestKey] = .object(merged)
            } else {
                result[nestKey] = .object(group)
            }
        }

        return .object(result)
    }

    /// Value compaction — [JSON-LD 1.1 API §8.10](https://www.w3.org/TR/json-ld11-api/#value-compaction).
    private static func compactValue(
        _ map: [String: JSON],
        activeProperty: String?,
        ctx: ActiveContext,
        inverse: InverseContext
    ) throws(JSONLD.Error) -> JSON {
        let termDef = activeProperty.flatMap { ctx.termDefinitions[$0] }
        let typeMapping = termDef?.typeMapping
        let langMapping: String? = {
            if case .tag(let lang) = termDef?.languageMapping { return lang.lowercased() }
            if termDef?.languageMapping == nil { return ctx.defaultLanguage?.lowercased() }
            return nil  // explicit @language: null
        }()
        let dirMapping: String? = {
            switch termDef?.directionMapping {
            case .some(.ltr): return "ltr"
            case .some(.rtl): return "rtl"
            default:
                switch ctx.defaultBaseDirection {
                case .some(.ltr): return "ltr"
                case .some(.rtl): return "rtl"
                default: return nil
                }
            }
        }()
        let container = termDef?.containerMapping ?? []
        let preserveIndex = map["@index"] != nil && !container.contains(.index)

        let mapType: String? = {
            if case .string(let s) = map["@type"] ?? .null { return s }
            return nil
        }()
        let mapLang: String? = {
            if case .string(let s) = map["@language"] ?? .null { return s.lowercased() }
            return nil
        }()
        let mapDir: String? = {
            if case .string(let s) = map["@direction"] ?? .null { return s }
            return nil
        }()

        if !preserveIndex, typeMapping != "@none" {
            // Type match
            if let mt = mapType, mt == typeMapping {
                return map["@value"]!
            }
            // Language + direction match
            if mapLang != nil, mapLang == langMapping, mapDir == dirMapping {
                return map["@value"]!
            }
            // Language only
            if mapLang != nil, mapLang == langMapping {
                return map["@value"]!
            }
            // Direction only
            if mapDir != nil, mapDir == dirMapping {
                return map["@value"]!
            }
        }
        // {"@value": v} sole key, with no default-language string concern.
        let keyCount = map.keys.count
        let isValueOnlyKey = (keyCount == 1 || (keyCount == 2 && map["@index"] != nil && !preserveIndex))
        let hasDefaultLanguage = ctx.defaultLanguage != nil
        let isValueString: Bool = {
            if case .string = map["@value"] ?? .null { return true }
            return false
        }()
        let hasNullMapping: Bool = {
            if case .null = termDef?.languageMapping { return true }
            return false
        }()
        if isValueOnlyKey, typeMapping != "@none",
           (!hasDefaultLanguage || !isValueString || hasNullMapping)
        {
            return map["@value"]!
        }

        // Otherwise: rewrite keys via inverse compaction.
        var out: [String: JSON] = [:]
        for (k, v) in map {
            if k == "@type", case .string(let s) = v {
                let aliased = try inverse.compact("@type", activeContext: ctx)
                out[aliased] = .string(try inverse.compact(s, activeContext: ctx, vocab: true))
            } else if k == "@value" || k == "@language" || k == "@direction" || k == "@index" {
                let aliased = try inverse.compact(k, activeContext: ctx)
                out[aliased] = v
            } else {
                out[k] = v
            }
        }
        return .object(out)
    }
}
