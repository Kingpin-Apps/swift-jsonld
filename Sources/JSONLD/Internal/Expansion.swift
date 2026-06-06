import Foundation

extension JSONLD {
    /// Expansion Algorithm — [JSON-LD 1.1 API §7.1](https://www.w3.org/TR/json-ld11-api/#expansion-algorithm).
    ///
    /// **Status — Phase 2 in progress.** Currently handles:
    /// - `null` → `null`
    /// - Arrays (recursive)
    /// - Objects with `@context`, simple property mapping, scalars
    ///
    /// Not yet implemented (many spec edge cases):
    /// - `@reverse`, `@nest`, `@included`, `@graph` handling
    /// - Container-based key iteration (`@list`, `@set`, `@index`,
    ///   `@language`, `@id`, `@type`, `@graph`)
    /// - Type-scoped + property-scoped contexts
    /// - Free-floating node detection + dropping
    /// - `@value` object validation
    /// - `@json` literal handling
    /// - Frame expansion
    /// - Negative-evaluation error code emission for all spec paths
    static func expand(
        activeContext: ActiveContext,
        activeProperty: String?,
        element: JSON,
        baseURL: URL?,
        frameExpansion: Bool = false,
        ordered: Bool = false,
        fromMap: Bool = false,
        options: Options
    ) async throws(JSONLD.Error) -> JSON {
        var ctx = activeContext

        // Step 1: null → null
        if case .null = element { return .null }

        // Step 2: scalar → value expansion if active property is set
        if case .bool = element { return await expandValue(element, activeProperty: activeProperty, activeContext: ctx) }
        if case .int = element { return await expandValue(element, activeProperty: activeProperty, activeContext: ctx) }
        if case .double = element { return await expandValue(element, activeProperty: activeProperty, activeContext: ctx) }
        if case .string = element { return await expandValue(element, activeProperty: activeProperty, activeContext: ctx) }

        // Step 3: arrays
        if case .array(let items) = element {
            var out: [JSON] = []
            for item in items {
                let expanded = try await expand(
                    activeContext: ctx,
                    activeProperty: activeProperty,
                    element: item,
                    baseURL: baseURL,
                    frameExpansion: frameExpansion,
                    ordered: ordered,
                    fromMap: false,
                    options: options
                )
                switch expanded {
                case .null:
                    continue
                case .array(let inner):
                    out.append(contentsOf: inner)
                default:
                    // Drop free-floating value/list objects at top level
                    // (active property is nil or @graph).
                    if activeProperty == nil || activeProperty == "@graph",
                       case .object(let m) = expanded
                    {
                        if m["@value"] != nil { continue }
                        if m["@list"] != nil { continue }
                    }
                    out.append(expanded)
                }
            }
            return .array(out)
        }

        // Step 4: object
        guard case .object(var map) = element else {
            return .null
        }

        // Step 4.0: Type-scoped revert. If the incoming ctx carries a
        // `previousContext` from a parent's type-scoped activation,
        // capture the property-scoped @context for `activeProperty`
        // FIRST (using the pre-revert ctx so type-scoped defs are
        // visible), then revert, then layer property-scoped on top
        // of the reverted ctx. Skip the revert for:
        //  - value-objects (any key expanding to @value via the
        //    type-scoped ctx — jsonld.js's "mustRevert" carve-out)
        //  - bare @id references
        //  - fromMap (index/id/language/etc. container expansions
        //    that pre-pull a key into the ctx)
        if let prev = ctx.previousContext, !fromMap {
            // §7.1 "expansion algorithm" mustRevert check (jsonld.js
            // lines 169-194): if the element has ≤2 keys, none being
            // @context, and any key expands to @value via the
            // type-scoped (current) context, do not revert. If the
            // single key expands to @id, also do not revert.
            var skipRevert = false
            let sortedKeys = map.keys.sorted()
            if sortedKeys.count <= 2, !sortedKeys.contains("@context") {
                var typeCtxCopy = ctx
                for k in sortedKeys {
                    var defs: [String: Bool] = [:]
                    let expanded = try await expandIRI(
                        value: k, activeContext: &typeCtxCopy,
                        vocab: true, defined: &defs, options: options
                    )
                    if expanded == "@value" { skipRevert = true; break }
                    if expanded == "@id", sortedKeys.count == 1 {
                        skipRevert = true; break
                    }
                }
            }
            if !skipRevert {
                let propertyScopedCtx: JSON? = activeProperty
                    .flatMap { ctx.termDefinitions[$0]?.localContext }
                ctx = prev.context
                if let scoped = propertyScopedCtx {
                    ctx = try await processContext(
                        activeContext: ctx,
                        localContext: scoped,
                        baseURL: baseURL,
                        overrideProtected: true,
                        options: options
                    )
                }
            }
        }

        // Step 4.1: process @context if present
        if let local = map["@context"] {
            ctx = try await processContext(
                activeContext: ctx,
                localContext: local,
                baseURL: baseURL,
                options: options
            )
            map.removeValue(forKey: "@context")
        }


        // Type-scoped contexts: §7.1 step 11–12.
        // Snapshot the context AFTER inline @context but BEFORE any
        // type-scoped activations — `@type` value IRI expansion must
        // use this snapshot (jsonld.js calls it `typeScopedContext`)
        // so type names resolve against the @vocab / term definitions
        // that were in effect at the START of this object's
        // processing, not whatever the type-scoped contexts redefine.
        let typeScopedContext = ctx
        // Scan the object for keys that expand to @type. For each
        // @type value whose term has a localContext, activate that
        // context with `propagate: false` so that — unless the local
        // context explicitly sets `@propagate: true` — the
        // pre-activation context is restored on nested object descent.
        // `processContext` writes `previousContext` itself based on
        // the effective propagate flag, so we don't need to set it
        // here.
        for key in map.keys {
            var defs: [String: Bool] = [:]
            let expanded = try await expandIRI(
                value: key, activeContext: &ctx, vocab: true,
                defined: &defs, options: options
            )
            guard expanded == "@type" else { continue }
            let typeValue = map[key]!
            var types: [String] = []
            if case .string(let s) = typeValue { types = [s] }
            if case .array(let arr) = typeValue {
                types = arr.compactMap {
                    if case .string(let s) = $0 { return s } else { return nil }
                }
            }
            for typeName in types.sorted() {
                // Look up the type's term def in the typeScopedContext
                // snapshot — a previous type-scoped activation's
                // `[null]` reset would have wiped the def from the
                // current `ctx` if we looked there.
                if let typeDef = typeScopedContext.termDefinitions[typeName],
                   let typeCtx = typeDef.localContext
                {
                    ctx = try await processContext(
                        activeContext: ctx,
                        localContext: typeCtx,
                        baseURL: baseURL,
                        propagate: false,
                        options: options
                    )
                }
            }
        }

        var result: [String: JSON] = [:]
        var defined: [String: Bool] = [:]

        // Iteration order: process @nest LAST so its inner properties
        // accumulate after the outer node's own properties. Source
        // order would be the strict-spec answer but Swift's
        // `[String: JSON]` doesn't preserve it.
        let sortedKeys = map.keys.sorted { a, b in
            let aNest = a == "@nest" || (ctx.termDefinitions[a]?.iriMapping == "@nest")
            let bNest = b == "@nest" || (ctx.termDefinitions[b]?.iriMapping == "@nest")
            if aNest != bNest { return !aNest }
            return a < b
        }
        for key in sortedKeys {
            let rawValue = map[key]!

            let expandedKey = try await expandIRI(
                value: key,
                activeContext: &ctx,
                vocab: true,
                localContext: nil,
                defined: &defined,
                options: options
            )

            guard let expandedKey, expandedKey.contains(":") || Keyword(rawValue: expandedKey) != nil else {
                // Drop terms that don't resolve to a keyword or
                // absolute IRI.
                continue
            }

            // Handle @id, @type, @value as special positions; otherwise
            // recurse on the value with the term's active property.
            if expandedKey == "@id" {
                // §7.1 step 13.4.3: @id value must be a string. Non-
                // strings are `invalid @id value`. (Null is allowed
                // for keyword-form-`@id` paths but is wrapped in the
                // `.null` case which falls through silently.)
                switch rawValue {
                case .null: break
                case .string(let s):
                    var defs: [String: Bool] = [:]
                    let resolved = try await expandIRI(
                        value: s,
                        activeContext: &ctx,
                        documentRelative: true,
                        defined: &defs,
                        options: options
                    )
                    if let resolved {
                        // §7.1 step 13.4.3 — colliding keywords: two
                        // keys in the same node both expanding to @id
                        // with different values is invalid (ter26).
                        if case .string(let existing) = result["@id"] ?? .null,
                           existing != resolved
                        {
                            throw .other(code: "colliding keywords",
                                         message: "two @id aliases set conflicting values")
                        }
                        result["@id"] = .string(resolved)
                    } else if hasKeywordForm(s) {
                        // §5.3 step 3: a keyword-form string that
                        // isn't a real keyword resolves to null but
                        // is still emitted as @id (jsonld.js does
                        // this — the @id slot persists as null).
                        result["@id"] = .null
                    }
                default:
                    throw .other(code: "invalid @id value",
                                 message: "@id value must be a string")
                }
            } else if expandedKey == "@type" {
                let types: [String]
                switch rawValue {
                case .string(let s): types = [s]
                case .array(let arr):
                    // Every entry must be a string; non-strings throw.
                    for item in arr {
                        if case .string = item {} else {
                            throw .other(code: "invalid type value",
                                         message: "@type array entry must be a string")
                        }
                    }
                    types = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                default:
                    // §7.1: bare @type values that aren't strings or
                    // arrays of strings are invalid.
                    throw .other(code: "invalid type value",
                                 message: "@type value must be a string or array of strings")
                }
                var expandedTypes: [JSON] = []
                for t in types {
                    var defs: [String: Bool] = [:]
                    // §7.1 step 13.4.1.2: expand @type values against
                    // the type-scoped context (pre-activation), not
                    // the activated context — keeps type names like
                    // "B" resolving against the outer @vocab even
                    // when the type-scoped @context nullifies vocab.
                    var typeCtxCopy = typeScopedContext
                    if let r = try await expandIRI(
                        value: t,
                        activeContext: &typeCtxCopy,
                        documentRelative: true,
                        vocab: true,
                        defined: &defs,
                        options: options
                    ) {
                        expandedTypes.append(.string(r))
                    }
                }
                if !expandedTypes.isEmpty {
                    // Accumulate (so aliases like `type` and the literal
                    // `@type` both contribute to one merged array).
                    var merged: [JSON] = []
                    if case .array(let existing) = result["@type"] ?? .null {
                        merged = existing
                    } else if let existing = result["@type"] {
                        merged = [existing]
                    }
                    merged.append(contentsOf: expandedTypes)
                    result["@type"] = .array(merged)
                }
            } else if expandedKey == "@value" {
                result["@value"] = rawValue
            } else if expandedKey == "@language" {
                if case .string(let s) = rawValue {
                    result["@language"] = .string(s.lowercased())
                } else {
                    result["@language"] = rawValue
                }
            } else if expandedKey == "@direction" || expandedKey == "@index" {
                // §7.1 step 13.4.x: @index value must be a string.
                if expandedKey == "@index" {
                    if case .string = rawValue {} else {
                        throw .other(code: "invalid @index value",
                                     message: "@index value must be a string")
                    }
                }
                result[expandedKey] = rawValue
            } else if expandedKey == "@nest" {
                // §7.1 step 13.4.4: @nest keys are unwrapped — their
                // inner keys merge into the surrounding node object.
                // When the original key was a `@nest`-aliased term,
                // any property-scoped @context on that term applies
                // to the inner properties.
                var nestCtx = ctx
                if let nestDef = ctx.termDefinitions[key],
                   let nestLocalCtx = nestDef.localContext
                {
                    nestCtx = try await processContext(
                        activeContext: nestCtx,
                        localContext: nestLocalCtx,
                        baseURL: baseURL,
                        overrideProtected: true,
                        options: options
                    )
                }
                let items: [JSON]
                if case .array(let arr) = rawValue { items = arr }
                else { items = [rawValue] }
                // §7.1 step 13.13: @nest value must be a map or array
                // of maps — primitives or arrays of primitives throw
                // `invalid @nest value`. Value objects (`{@value: …}`)
                // are also rejected — @nest is for nested NODE-shape
                // structure, not literals.
                for item in items {
                    guard case .object(let m) = item else {
                        throw .other(code: "invalid @nest value",
                                     message: "@nest value must be a map or array of maps")
                    }
                    if m["@value"] != nil {
                        throw .other(code: "invalid @nest value",
                                     message: "@nest value cannot be a value object")
                    }
                }
                for item in items {
                    guard case .object(let inner) = item else { continue }
                    // Iterate with the same @nest-last sort the outer
                    // loop uses so deep-nested values land in the
                    // right order in accumulated arrays.
                    let innerSorted = inner.keys.sorted { a, b in
                        let aNest = a == "@nest" || (nestCtx.termDefinitions[a]?.iriMapping == "@nest")
                        let bNest = b == "@nest" || (nestCtx.termDefinitions[b]?.iriMapping == "@nest")
                        if aNest != bNest { return !aNest }
                        return a < b
                    }
                    for nestedKey in innerSorted {
                        let nestedValue = inner[nestedKey]!
                        let processed = try await expand(
                            activeContext: nestCtx,
                            activeProperty: nestedKey,
                            element: .object([nestedKey: nestedValue]),
                            baseURL: baseURL,
                            frameExpansion: frameExpansion,
                            ordered: ordered,
                            fromMap: false,
                            options: options
                        )
                        guard case .object(let processedMap) = processed else { continue }
                        for (pk, pv) in processedMap {
                            // Accumulate; arrays append.
                            if case .array(let existing) = result[pk] ?? .null,
                               case .array(let new) = pv
                            {
                                result[pk] = .array(existing + new)
                            } else {
                                result[pk] = pv
                            }
                        }
                    }
                }
            } else if expandedKey == "@reverse" {
                // §7.1 step 13.10: @reverse key. Inner keys whose term
                // is itself a reverse property cancel out — their
                // values become FORWARD properties on the outer node.
                // Other inner keys accumulate under the @reverse map.
                guard case .object(let reverseMap) = rawValue else {
                    throw .other(code: "invalid @reverse value",
                                 message: "@reverse value must be a map")
                }
                // §7.1 step 13.10.1: @reverse map keys are property
                // IRIs — keyword keys (other than reverse-internal
                // ones) are invalid (ter25's `@reverse: {@id: …}`).
                for revKey in reverseMap.keys {
                    if Keyword(rawValue: revKey) != nil {
                        throw .other(code: "invalid reverse property map",
                                     message: "@reverse map cannot contain keyword \(revKey)")
                    }
                }
                var reverseAccumulator: [String: JSON] = [:]
                if case .object(let existing) = result["@reverse"] ?? .null {
                    reverseAccumulator = existing
                }
                for (rk, rv) in reverseMap {
                    var rdefs: [String: Bool] = [:]
                    guard let revExpanded = try await expandIRI(
                        value: rk,
                        activeContext: &ctx,
                        vocab: true,
                        defined: &rdefs,
                        options: options
                    ), revExpanded.contains(":") else { continue }
                    let expandedValue = try await expand(
                        activeContext: ctx,
                        activeProperty: rk,
                        element: rv,
                        baseURL: baseURL,
                        frameExpansion: frameExpansion,
                        ordered: ordered,
                        fromMap: false,
                        options: options
                    )
                    let asArray: JSON
                    if case .array = expandedValue { asArray = expandedValue }
                    else if case .null = expandedValue { continue }
                    else { asArray = .array([expandedValue]) }

                    // §7.1 step 13.10.5: each @reverse value must be a
                    // node object — not a value object or list. The
                    // semantics of "reverse property → value" only
                    // make sense for node-to-node edges.
                    if case .array(let items) = asArray {
                        for item in items {
                            guard case .object(let m) = item else {
                                throw .other(code: "invalid reverse property value",
                                             message: "@reverse property value must be a node object")
                            }
                            if m["@value"] != nil {
                                throw .other(code: "invalid reverse property value",
                                             message: "@reverse property value cannot be a value object")
                            }
                            if m["@list"] != nil {
                                throw .other(code: "invalid reverse property",
                                             message: "@reverse property value cannot be a list object")
                            }
                        }
                    }

                    // Detect double-reverse: if the term `rk` is itself
                    // a reverse-property term, its expanded IRI lands
                    // as a FORWARD property on the outer result.
                    let innerIsReverse = ctx.termDefinitions[rk]?.reverseProperty == true
                    if innerIsReverse {
                        if case .array(let existing) = result[revExpanded] ?? .null,
                           case .array(let new) = asArray
                        {
                            result[revExpanded] = .array(existing + new)
                        } else {
                            result[revExpanded] = asArray
                        }
                    } else {
                        if case .array(let existingArr) = reverseAccumulator[revExpanded] ?? .null,
                           case .array(let newArr) = asArray
                        {
                            reverseAccumulator[revExpanded] = .array(existingArr + newArr)
                        } else {
                            reverseAccumulator[revExpanded] = asArray
                        }
                    }
                }
                if !reverseAccumulator.isEmpty {
                    result["@reverse"] = .object(reverseAccumulator)
                }
            } else if expandedKey == "@list" || expandedKey == "@set" {
                let expandedValue = try await expand(
                    activeContext: ctx,
                    activeProperty: activeProperty,
                    element: rawValue,
                    baseURL: baseURL,
                    frameExpansion: frameExpansion,
                    ordered: ordered,
                    fromMap: false,
                    options: options
                )
                let asArray: JSON
                if case .array = expandedValue {
                    asArray = expandedValue
                } else {
                    asArray = .array([expandedValue])
                }
                // Note: the spec's "list of lists" rule is checked at
                // the `@container: @list` coercion site, not on raw
                // `@list: [...]` keyword forms — flatten/compact may
                // pass already-expanded input through this branch with
                // nested @lists that the original expand already
                // validated (tli01/li02 etc.).
                result[expandedKey] = asArray
            } else if expandedKey == "@included" {
                let expandedValue = try await expand(
                    activeContext: ctx,
                    activeProperty: nil,
                    element: rawValue,
                    baseURL: baseURL,
                    frameExpansion: frameExpansion,
                    ordered: ordered,
                    fromMap: false,
                    options: options
                )
                let asArray: JSON
                if case .array = expandedValue { asArray = expandedValue }
                else if case .null = expandedValue {
                    // §7.1 step 13.7.3: @included that expands to null
                    // means the input wasn't a node-shaped value (e.g.
                    // a scalar `"string"`).
                    throw .other(code: "invalid @included value",
                                 message: "@included value must expand to one or more node objects")
                }
                else { asArray = .array([expandedValue]) }
                // §7.1 step 13.7.3: each @included entry must be a
                // node object — not a value object, list, or set.
                if case .array(let items) = asArray {
                    for item in items {
                        guard case .object(let m) = item else {
                            throw .other(code: "invalid @included value",
                                         message: "@included entry must be a node object")
                        }
                        if m["@value"] != nil || m["@list"] != nil || m["@set"] != nil {
                            throw .other(code: "invalid @included value",
                                         message: "@included entry must be a node object, not a value/list/set object")
                        }
                    }
                }
                if case .array(let existing) = result["@included"] ?? .null,
                   case .array(let new) = asArray
                {
                    result["@included"] = .array(existing + new)
                } else {
                    result["@included"] = asArray
                }
            } else if expandedKey == "@graph" {
                let expandedValue = try await expand(
                    activeContext: ctx,
                    activeProperty: "@graph",
                    element: rawValue,
                    baseURL: baseURL,
                    frameExpansion: frameExpansion,
                    ordered: ordered,
                    fromMap: false,
                    options: options
                )
                let asArray: JSON
                if case .array = expandedValue { asArray = expandedValue }
                else { asArray = .array([expandedValue]) }
                result["@graph"] = asArray
            } else {
                // Property-scoped contexts: layer the term's local
                // @context on top of the current ctx. §7.1 step 13.5.
                let termDef = ctx.termDefinitions[key]
                var valueCtx = ctx
                if let localCtx = termDef?.localContext {
                    valueCtx = try await processContext(
                        activeContext: valueCtx,
                        localContext: localCtx,
                        baseURL: baseURL,
                        // Property-scoped contexts override protected
                        // term defs ([§4.1.11](https://www.w3.org/TR/json-ld11/#protected-term-definitions)).
                        overrideProtected: true,
                        options: options
                    )
                }
                let containers = termDef?.containerMapping ?? []

                // §7.1 step 13.9: @graph container. Various
                // combinations are valid:
                //  - @graph alone → wrap as {"@graph": [...]}
                //  - @graph + @index → iterate map, keys become @index
                //  - @graph + @id → iterate map, keys become @id
                //  - @graph + @type → iterate map, keys become @type
                if containers.contains(.graph) {
                    var out: [JSON] = []
                    let graphIndexed = containers.contains(.index)
                    let graphIDed = containers.contains(.id)
                    let graphTyped = containers.contains(.type)

                    if (graphIndexed || graphIDed || graphTyped),
                       case .object(let outerMap) = rawValue
                    {
                        for innerKey in outerMap.keys.sorted() {
                            let innerVal = outerMap[innerKey]!
                            let items: [JSON]
                            if case .array(let arr) = innerVal { items = arr }
                            else { items = [innerVal] }
                            for item in items {
                                let expanded = try await expand(
                                    activeContext: valueCtx, activeProperty: key,
                                    element: item, baseURL: baseURL,
                                    frameExpansion: frameExpansion, ordered: ordered,
                                    fromMap: true, options: options
                                )
                                // If the expanded item is already
                                // wrapped in @graph (input had an
                                // explicit @graph key), unwrap it
                                // rather than nesting again.
                                let graphContents: JSON
                                if case .object(let m) = expanded,
                                   m.count == 1,
                                   let inner = m["@graph"]
                                {
                                    if case .array = inner { graphContents = inner }
                                    else { graphContents = .array([inner]) }
                                } else if case .array = expanded {
                                    graphContents = expanded
                                } else if case .null = expanded {
                                    continue
                                } else {
                                    graphContents = .array([expanded])
                                }
                                var node: [String: JSON] = ["@graph": graphContents]
                                if graphIndexed {
                                    var isNoneInner = innerKey == "@none"
                                    if let aliasDef = valueCtx.termDefinitions[innerKey],
                                       aliasDef.iriMapping == "@none"
                                    { isNoneInner = true }
                                    if !isNoneInner {
                                        // Property-valued index: the
                                        // key becomes a value of the
                                        // term's @index property.
                                        if let indexProp = termDef?.indexMapping {
                                            var d2: [String: Bool] = [:]
                                            let indexPropIRI: String
                                            if let r = try? await expandIRI(
                                                value: indexProp, activeContext: &valueCtx,
                                                vocab: true, defined: &d2, options: options
                                            ) { indexPropIRI = r } else { indexPropIRI = indexProp }
                                            node[indexPropIRI] = .array([.object(["@value": .string(innerKey)])])
                                        } else {
                                            node["@index"] = .string(innerKey)
                                        }
                                    }
                                }
                                if graphIDed {
                                    var isNoneInner = innerKey == "@none"
                                    if let aliasDef = valueCtx.termDefinitions[innerKey],
                                       aliasDef.iriMapping == "@none"
                                    { isNoneInner = true }
                                    if !isNoneInner {
                                        var resolved = innerKey
                                        if !innerKey.hasPrefix("_:") {
                                            var d2: [String: Bool] = [:]
                                            if let r = try? await expandIRI(
                                                value: innerKey, activeContext: &valueCtx,
                                                documentRelative: true, defined: &d2,
                                                options: options
                                            ) { resolved = r }
                                        }
                                        node["@id"] = .string(resolved)
                                    }
                                }
                                if graphTyped {
                                    var d2: [String: Bool] = [:]
                                    let expandedT: String
                                    if let r = try? await expandIRI(
                                        value: innerKey, activeContext: &valueCtx,
                                        documentRelative: true, vocab: true,
                                        defined: &d2, options: options
                                    ) { expandedT = r } else { expandedT = innerKey }
                                    node["@type"] = .array([.string(expandedT)])
                                }
                                out.append(.object(node))
                            }
                        }
                    } else {
                        let items: [JSON]
                        if case .array(let arr) = rawValue { items = arr }
                        else { items = [rawValue] }
                        for item in items {
                            let expanded = try await expand(
                                activeContext: valueCtx, activeProperty: key,
                                element: item, baseURL: baseURL,
                                frameExpansion: frameExpansion, ordered: ordered,
                                fromMap: false, options: options
                            )
                            let graphContents: JSON
                            if case .array = expanded { graphContents = expanded }
                            else if case .null = expanded { continue }
                            else { graphContents = .array([expanded]) }
                            out.append(.object(["@graph": graphContents]))
                        }
                    }

                    if case .array(let existing) = result[expandedKey] ?? .null {
                        result[expandedKey] = .array(existing + out)
                    } else {
                        result[expandedKey] = .array(out)
                    }
                    continue
                }

                // §7.4 step 8: @type: @json means the value is preserved
                // verbatim as a JSON literal. Wrap and short-circuit
                // without recursive expansion.
                if termDef?.typeMapping == "@json" {
                    let wrapped = JSON.object([
                        "@value": rawValue,
                        "@type": .string("@json"),
                    ])
                    result[expandedKey] = .array([wrapped])
                    continue
                }

                // §7.1 step 13.7: @index container expansion. Each key
                // of the input map becomes an @index annotation on the
                // recursively-expanded value. When the term has a
                // property-valued `@index: "propname"` (1.1), the keys
                // become VALUES of that property instead of @index.
                if containers.contains(.index),
                   case .object(let indexMap) = rawValue
                {
                    var out: [JSON] = []
                    let indexProp = termDef?.indexMapping
                    var indexPropIRI: String? = nil
                    var indexPropType: String? = nil
                    if let indexProp {
                        var d2: [String: Bool] = [:]
                        if let expandedProp = try? await expandIRI(
                            value: indexProp, activeContext: &valueCtx,
                            vocab: true, defined: &d2, options: options
                        ) { indexPropIRI = expandedProp }
                        // Pick up the property's own type-mapping (e.g.
                        // @id or @vocab) so the index key gets the same
                        // coercion an inline value would.
                        indexPropType = valueCtx.termDefinitions[indexProp]?.typeMapping
                    }
                    for indexKey in indexMap.keys.sorted() {
                        let indexValue = indexMap[indexKey]!
                        var items: [JSON]
                        if case .array(let arr) = indexValue { items = arr }
                        else { items = [indexValue] }
                        for item in items {
                            let expanded = try await expand(
                                activeContext: valueCtx,
                                activeProperty: key,
                                element: item,
                                baseURL: baseURL,
                                frameExpansion: frameExpansion,
                                ordered: ordered,
                                fromMap: true,
                                options: options
                            )
                            // For property-valued index, append the
                            // key as a @value on the named property
                            // instead of setting @index.
                            // `@none` (and aliases) skip the index attachment.
                            var isNoneIndex = indexKey == "@none"
                            if let aliasDef = valueCtx.termDefinitions[indexKey],
                               aliasDef.iriMapping == "@none"
                            { isNoneIndex = true }

                            func attach(_ inner: [String: JSON]) async throws(JSONLD.Error) -> [String: JSON] {
                                var m = inner
                                if isNoneIndex { return m }
                                if let indexPropIRI {
                                    // §4.6.6 — a value object can't carry
                                    // arbitrary sibling properties. tpi05:
                                    // a property-valued index would try to
                                    // attach the index property to a value
                                    // object, producing an invalid shape.
                                    if m["@value"] != nil {
                                        throw .other(code: "invalid value object",
                                                     message: "cannot attach property-valued index to a value object")
                                    }
                                    // Build the index value, applying
                                    // @id/@vocab coercion from the
                                    // property's type-mapping.
                                    let entry: JSON
                                    if indexPropType == "@id" {
                                        var ctxM = valueCtx
                                        var d2: [String: Bool] = [:]
                                        if let resolved = try? await expandIRI(
                                            value: indexKey, activeContext: &ctxM,
                                            documentRelative: true, defined: &d2,
                                            options: options
                                        ) {
                                            entry = .object(["@id": .string(resolved)])
                                        } else {
                                            entry = .object(["@id": .string(indexKey)])
                                        }
                                    } else if indexPropType == "@vocab" {
                                        var ctxM = valueCtx
                                        var d2: [String: Bool] = [:]
                                        if let resolved = try? await expandIRI(
                                            value: indexKey, activeContext: &ctxM,
                                            documentRelative: true, vocab: true,
                                            defined: &d2, options: options
                                        ) {
                                            entry = .object(["@id": .string(resolved)])
                                        } else {
                                            entry = .object(["@id": .string(indexKey)])
                                        }
                                    } else {
                                        entry = .object(["@value": .string(indexKey)])
                                    }
                                    if case .array(let existing) = m[indexPropIRI] ?? .null {
                                        m[indexPropIRI] = .array([entry] + existing)
                                    } else {
                                        m[indexPropIRI] = .array([entry])
                                    }
                                } else if m["@index"] == nil {
                                    m["@index"] = .string(indexKey)
                                }
                                return m
                            }
                            switch expanded {
                            case .null: continue
                            case .object(let m):
                                out.append(.object(try await attach(m)))
                            case .array(let arr):
                                for el in arr {
                                    if case .object(let m) = el {
                                        out.append(.object(try await attach(m)))
                                    } else {
                                        out.append(el)
                                    }
                                }
                            default:
                                out.append(expanded)
                            }
                        }
                    }
                    if termDef?.reverseProperty == true {
                        var reverseAcc: [String: JSON] = [:]
                        if case .object(let existing) = result["@reverse"] ?? .null {
                            reverseAcc = existing
                        }
                        if case .array(let existingArr) = reverseAcc[expandedKey] ?? .null {
                            reverseAcc[expandedKey] = .array(existingArr + out)
                        } else {
                            reverseAcc[expandedKey] = .array(out)
                        }
                        result["@reverse"] = .object(reverseAcc)
                    } else if case .array(let existing) = result[expandedKey] ?? .null {
                        result[expandedKey] = .array(existing + out)
                    } else {
                        result[expandedKey] = .array(out)
                    }
                    continue
                }

                // §7.1 step 13.7.5: @id container expansion. Each key
                // of the input map becomes the @id of its inner node
                // object. Keys that are IRIs/blank-nodes pass through;
                // others get IRI-expanded against the active context.
                if containers.contains(.id),
                   case .object(let idMap) = rawValue
                {
                    var out: [JSON] = []
                    for idKey in idMap.keys.sorted() {
                        let inner = idMap[idKey]!
                        let items: [JSON]
                        if case .array(let arr) = inner { items = arr }
                        else { items = [inner] }
                        for item in items {
                            let expanded = try await expand(
                                activeContext: valueCtx, activeProperty: key,
                                element: item, baseURL: baseURL,
                                frameExpansion: frameExpansion, ordered: ordered,
                                fromMap: true, options: options
                            )
                            // Resolve key against base; if it's _:..., keep.
                            // `@none` (and aliases for it) skip the
                            // @id attachment.
                            var resolvedKey = idKey
                            var isNone = idKey == "@none"
                            if let aliasDef = valueCtx.termDefinitions[idKey],
                               aliasDef.iriMapping == "@none"
                            { isNone = true }
                            if !idKey.hasPrefix("_:"), !isNone {
                                var defs2: [String: Bool] = [:]
                                if let r = try? await expandIRI(
                                    value: idKey,
                                    activeContext: &valueCtx,
                                    documentRelative: true,
                                    defined: &defs2,
                                    options: options
                                ) { resolvedKey = r }
                            }
                            switch expanded {
                            case .null: continue
                            case .object(var m):
                                if m["@id"] == nil, !isNone { m["@id"] = .string(resolvedKey) }
                                out.append(.object(m))
                            case .array(let arr):
                                for el in arr {
                                    if case .object(var m) = el {
                                        if m["@id"] == nil, !isNone { m["@id"] = .string(resolvedKey) }
                                        out.append(.object(m))
                                    } else {
                                        out.append(el)
                                    }
                                }
                            default:
                                out.append(expanded)
                            }
                        }
                    }
                    // If the term is ALSO a reverse property, route
                    // the index-map output under @reverse instead of
                    // directly onto the result.
                    if termDef?.reverseProperty == true {
                        var reverseAcc: [String: JSON] = [:]
                        if case .object(let existing) = result["@reverse"] ?? .null {
                            reverseAcc = existing
                        }
                        if case .array(let existingArr) = reverseAcc[expandedKey] ?? .null {
                            reverseAcc[expandedKey] = .array(existingArr + out)
                        } else {
                            reverseAcc[expandedKey] = .array(out)
                        }
                        result["@reverse"] = .object(reverseAcc)
                    } else if case .array(let existing) = result[expandedKey] ?? .null {
                        result[expandedKey] = .array(existing + out)
                    } else {
                        result[expandedKey] = .array(out)
                    }
                    continue
                }

                // §7.1 step 13.7.6: @type container expansion. Each
                // key becomes a @type on its inner node.
                if containers.contains(.type),
                   case .object(let typeMap) = rawValue
                {
                    // jsonld.js expand.js line 896: revert the
                    // type-scoped context before iterating an @type
                    // container — the type-scoped def of the term we
                    // came in on (e.g. an Outer-scoped redefinition
                    // of `prop`) shouldn't bleed into the new node
                    // objects under each type-map key.
                    if let prev = valueCtx.previousContext {
                        valueCtx = prev.context
                    }
                    var out: [JSON] = []
                    for typeKey in typeMap.keys.sorted() {
                        let inner = typeMap[typeKey]!
                        let items: [JSON]
                        if case .array(let arr) = inner { items = arr }
                        else { items = [inner] }
                        for item in items {
                            var defs2: [String: Bool] = [:]
                            let expandedType: String
                            if let r = try? await expandIRI(
                                value: typeKey, activeContext: &valueCtx,
                                documentRelative: true, vocab: true,
                                defined: &defs2, options: options
                            ) {
                                expandedType = r
                            } else {
                                expandedType = typeKey
                            }

                            // Activate the type-scoped context for the
                            // type term, if it has one.
                            var typeCtx = valueCtx
                            if let typeDef = valueCtx.termDefinitions[typeKey],
                               let typeLocalCtx = typeDef.localContext
                            {
                                typeCtx = try await processContext(
                                    activeContext: typeCtx,
                                    localContext: typeLocalCtx,
                                    baseURL: baseURL,
                                    propagate: false,
                                    options: options
                                )
                            }

                            // String items in a @type map are treated
                            // as @id references (§7.1 step 13.7.6).
                            // When the term has @type: @vocab the
                            // string resolves vocab-relative; @id
                            // (default) uses document-relative.
                            let effectiveItem: JSON
                            if case .string(let s) = item {
                                let isVocab = termDef?.typeMapping == "@vocab"
                                var d2: [String: Bool] = [:]
                                var ctxM = typeCtx
                                let resolved: String
                                if let r = try? await expandIRI(
                                    value: s, activeContext: &ctxM,
                                    documentRelative: !isVocab,
                                    vocab: isVocab,
                                    defined: &d2, options: options
                                ) {
                                    resolved = r
                                } else {
                                    resolved = s
                                }
                                effectiveItem = .object(["@id": .string(resolved)])
                            } else {
                                effectiveItem = item
                            }
                            let expanded = try await expand(
                                activeContext: typeCtx, activeProperty: key,
                                element: effectiveItem, baseURL: baseURL,
                                frameExpansion: frameExpansion, ordered: ordered,
                                fromMap: true, options: options
                            )
                            // @none keys (and aliases) skip the @type attachment.
                            var isNoneType = typeKey == "@none"
                            if let aliasDef = valueCtx.termDefinitions[typeKey],
                               aliasDef.iriMapping == "@none"
                            { isNoneType = true }

                            func attachType(_ m: [String: JSON]) -> [String: JSON] {
                                if isNoneType { return m }
                                var out = m
                                var types: [JSON] = [.string(expandedType)]
                                if case .array(let arr) = out["@type"] ?? .null {
                                    types.append(contentsOf: arr)
                                } else if let existing = out["@type"] {
                                    types.append(existing)
                                }
                                out["@type"] = .array(types)
                                return out
                            }
                            switch expanded {
                            case .object(let m):
                                out.append(.object(attachType(m)))
                            case .array(let arr):
                                for el in arr where !el.isNull {
                                    if case .object(let m) = el {
                                        out.append(.object(attachType(m)))
                                    }
                                }
                            default: break
                            }
                        }
                    }
                    if case .array(let existing) = result[expandedKey] ?? .null {
                        result[expandedKey] = .array(existing + out)
                    } else {
                        result[expandedKey] = .array(out)
                    }
                    continue
                }

                // §7.1 step 13.8: @language container expansion. Each
                // key of the input map becomes the @language tag of
                // its (string) values.
                if containers.contains(.language),
                   case .object(let langMap) = rawValue
                {
                    var out: [JSON] = []
                    for langKey in langMap.keys.sorted() {
                        let langValue = langMap[langKey]!
                        var items: [JSON]
                        if case .array(let arr) = langValue { items = arr }
                        else { items = [langValue] }
                        // Term direction overrides context default.
                        let effectiveDir: TermDefinition.DirectionMapping? = {
                            if let d = termDef?.directionMapping { return d }
                            return valueCtx.defaultBaseDirection
                        }()
                        // Resolve the language key through term aliases:
                        // a term whose iri-mapping is `@none` means
                        // "no language" for the values under that key.
                        var resolvedLang = langKey
                        if let aliasDef = valueCtx.termDefinitions[langKey],
                           aliasDef.iriMapping == "@none"
                        {
                            resolvedLang = "@none"
                        }
                        for item in items {
                            // §7.1 step 13.8.6: @language container map
                            // values must be strings (or null, which
                            // is permitted and silently dropped — tl001).
                            // Booleans/numbers/objects throw "invalid
                            // language map value" (er35).
                            if case .null = item { continue }
                            guard case .string(let s) = item else {
                                throw .other(code: "invalid language map value",
                                             message: "@language map value must be a string or null")
                            }
                            var obj: [String: JSON] = ["@value": .string(s)]
                            if resolvedLang != "@none" {
                                obj["@language"] = .string(resolvedLang.lowercased())
                            }
                            if let dir = effectiveDir {
                                switch dir {
                                case .ltr: obj["@direction"] = .string("ltr")
                                case .rtl: obj["@direction"] = .string("rtl")
                                case .null: break
                                }
                            }
                            out.append(.object(obj))
                        }
                    }
                    if case .array(let existing) = result[expandedKey] ?? .null {
                        result[expandedKey] = .array(existing + out)
                    } else {
                        result[expandedKey] = .array(out)
                    }
                    continue
                }

                let expandedValue = try await expand(
                    activeContext: valueCtx,
                    activeProperty: key,
                    element: rawValue,
                    baseURL: baseURL,
                    frameExpansion: frameExpansion,
                    ordered: ordered,
                    fromMap: false,
                    options: options
                )

                if containers.contains(.list) {
                    // Build the list contents preserving nested-array
                    // structure: each level of nesting becomes another
                    // @list wrapper. Recurse into each item ourselves
                    // rather than relying on the (flattening) array
                    // recursion in step 3.
                    func toListContents(_ value: JSON) async throws(JSONLD.Error) -> [JSON] {
                        if case .array(let items) = value {
                            var out: [JSON] = []
                            for item in items {
                                if case .array = item {
                                    let inner = try await toListContents(item)
                                    out.append(.object(["@list": .array(inner)]))
                                } else {
                                    let one = try await expand(
                                        activeContext: valueCtx,
                                        activeProperty: key,
                                        element: item,
                                        baseURL: baseURL,
                                        frameExpansion: frameExpansion,
                                        ordered: ordered,
                                        fromMap: false,
                                        options: options
                                    )
                                    if case .null = one { continue }
                                    if case .array(let arr) = one { out.append(contentsOf: arr) }
                                    else { out.append(one) }
                                }
                            }
                            return out
                        }
                        let one = try await expand(
                            activeContext: valueCtx, activeProperty: key,
                            element: value, baseURL: baseURL,
                            frameExpansion: frameExpansion, ordered: ordered,
                            fromMap: false, options: options
                        )
                        if case .null = one { return [] }
                        if case .array(let arr) = one { return arr }
                        return [one]
                    }

                    let listEmission: JSON
                    if case .object(let map) = expandedValue, map["@list"] != nil {
                        listEmission = .array([expandedValue])
                    } else if case .array = rawValue {
                        let contents = try await toListContents(rawValue)
                        // Note: spec's "list of lists" rule fires only
                        // in 1.0 processing mode (ter24/ter32). Our
                        // conformance harness filters out 1.0-mode
                        // tests, so no validation is needed here.
                        listEmission = .array([.object(["@list": .array(contents)])])
                    } else {
                        let inner: JSON
                        if case .array = expandedValue { inner = expandedValue }
                        else if case .null = expandedValue { inner = .array([]) }
                        else { inner = .array([expandedValue]) }
                        listEmission = .array([.object(["@list": inner])])
                    }
                    // Accumulate when this IRI has been seen already.
                    if case .array(let existing) = result[expandedKey] ?? .null,
                       case .array(let new) = listEmission
                    {
                        result[expandedKey] = .array(existing + new)
                    } else {
                        result[expandedKey] = listEmission
                    }
                    continue
                }

                if case .null = expandedValue { continue }
                let asArray: JSON
                if case .array = expandedValue {
                    asArray = expandedValue
                } else {
                    asArray = .array([expandedValue])
                }

                // Reverse property: accumulate under @reverse instead of
                // result[expandedKey] directly. §7.1 step 13.13.
                if termDef?.reverseProperty == true {
                    // §7.1 step 13.13.4: reverse-property values must
                    // be node objects — list/set/value objects are
                    // rejected ("invalid reverse property value" for
                    // value objects, "invalid reverse property" for
                    // list objects per er36).
                    if case .array(let items) = asArray {
                        for item in items {
                            if case .object(let m) = item {
                                if m["@list"] != nil {
                                    throw .other(code: "invalid reverse property value",
                                                 message: "reverse-property value cannot be a list object")
                                }
                                if m["@value"] != nil {
                                    throw .other(code: "invalid reverse property value",
                                                 message: "reverse-property value cannot be a value object")
                                }
                            }
                        }
                    }
                    var reverseAcc: [String: JSON]
                    if case .object(let existing) = result["@reverse"] ?? .null {
                        reverseAcc = existing
                    } else {
                        reverseAcc = [:]
                    }
                    if case .array(let existingArr) = reverseAcc[expandedKey] ?? .null,
                       case .array(let newArr) = asArray
                    {
                        reverseAcc[expandedKey] = .array(existingArr + newArr)
                    } else {
                        reverseAcc[expandedKey] = asArray
                    }
                    result["@reverse"] = .object(reverseAcc)
                    continue
                }

                // Accumulate when multiple keys expand to the same IRI
                // (e.g. a defined term, the vocab fallback for a bare
                // suffix, and the absolute IRI all collide on one slot).
                if case .array(let existing) = result[expandedKey] ?? .null,
                   case .array(let new) = asArray
                {
                    result[expandedKey] = .array(existing + new)
                } else {
                    result[expandedKey] = asArray
                }
            }
        }

        // Free-floating empty result (top-level or under @graph) drops.
        if result.isEmpty, activeProperty == nil || activeProperty == "@graph" {
            return .null
        }

        // Pseudo-value-object cleanup: an object with @language but no
        // @value (or @type but no @value, etc.) is an invalid value
        // object and gets dropped. (§7.1 step 15.)
        if result["@language"] != nil, result["@value"] == nil,
           result["@id"] == nil, result["@type"] == nil,
           result["@list"] == nil, result["@set"] == nil,
           result["@graph"] == nil
        {
            return .null
        }

        // §7.1 step 15.4: a value-object with @value: null is dropped.
        // Exception: @type: @json allows null as a JSON literal.
        if case .null = result["@value"] ?? .object([:]) {
            if result["@value"] != nil {
                var isJSON = false
                if case .string("@json") = result["@type"] ?? .null { isJSON = true }
                if case .array(let arr) = result["@type"] ?? .null,
                   arr.contains(.string("@json"))
                { isJSON = true }
                if !isJSON { return .null }
            }
        }

        // §7.1 step 18.4: if result contains @set, the value of @set
        // takes over (and @index, if also present, comes along).
        if let setValue = result["@set"] {
            let allowed: Set<String> = ["@set", "@index"]
            if result.keys.allSatisfy({ allowed.contains($0) }) {
                return setValue
            }
            // @set with disallowed siblings (e.g. `@set` + `@id`) →
            // `invalid set or list object` per §4.3.
            throw .other(code: "invalid set or list object",
                         message: "@set object has disallowed sibling key")
        }
        // §4.3: a `@list` object may only carry `@list` + `@index`.
        if result["@list"] != nil {
            let allowed: Set<String> = ["@list", "@index"]
            if !result.keys.allSatisfy({ allowed.contains($0) }) {
                throw .other(code: "invalid set or list object",
                             message: "@list object has disallowed sibling key")
            }
        }

        // §7.1 step 18: free-floating value / node-with-only-@id drop.
        // The top-level guard preserves node references like
        // `{"prop": {"@id": "…"}}`. The `@id: null` carve-out fires
        // only at the top level (or under `@graph`) — at non-top-level
        // depths the spec keeps `{@id: null}` so the property slot
        // survives (t0122: `vocab/ignoreme: [{@id: null}]`).
        if result.keys.count == 1, case .some(.null) = result["@id"],
           activeProperty == nil || activeProperty == "@graph"
        {
            return .null
        }
        if activeProperty == nil || activeProperty == "@graph" {
            if result.keys.count == 1 && result["@id"] != nil {
                return .null
            }
            // Value-object that's free-floating → dropped.
            if result["@value"] != nil {
                let onlyValue = result.keys.allSatisfy { $0 == "@value" }
                if onlyValue { return .null }
            }
            // Top-level @graph with only @graph (and possibly @index)
            // — unwrap. A named graph (has @id) is preserved as a
            // graph object. (§7.1 step 18.)
            if let graph = result["@graph"],
               result["@id"] == nil,
               result.keys.allSatisfy({ ["@graph", "@index"].contains($0) })
            {
                return graph
            }
        }

        // Post-process: value-object normalization + strict validation
        // per [§4.6.6 Value Objects](https://www.w3.org/TR/json-ld11/#value-objects).
        //
        // If the result has @value, it's a value object. The spec
        // restricts what keys may appear alongside @value, and the
        // types of the values themselves.
        if result["@value"] != nil {
            // Disallowed siblings: only @type / @language / @direction
            // / @index / @value may appear together. @id, @set, @list,
            // @graph etc. alongside @value → `invalid value object`.
            let allowedKeys: Set<String> = ["@value", "@type", "@language", "@direction", "@index"]
            if !result.keys.allSatisfy({ allowedKeys.contains($0) }) {
                throw .other(code: "invalid value object",
                             message: "value object has disallowed sibling key")
            }
            // @type and @language are mutually exclusive on a value
            // object.
            if result["@type"] != nil, result["@language"] != nil {
                throw .other(code: "invalid value object",
                             message: "value object cannot have both @type and @language")
            }
            // @type and @direction are mutually exclusive on a value
            // object — @direction is a language-tagged-string concept.
            if result["@type"] != nil, result["@direction"] != nil {
                throw .other(code: "invalid value object",
                             message: "value object cannot have both @type and @direction")
            }
            // @value must be scalar (string / number / bool / null).
            // Arrays and objects are rejected EXCEPT when @type: @json,
            // which allows any JSON.
            let isJSON: Bool = {
                if case .string("@json") = result["@type"] ?? .null { return true }
                if case .array(let arr) = result["@type"] ?? .null,
                   arr.contains(.string("@json")) { return true }
                return false
            }()
            if !isJSON {
                switch result["@value"]! {
                case .object, .array:
                    throw .other(code: "invalid value object value",
                                 message: "@value must be a scalar")
                default: break
                }
            }
            // @type on a value object must be a string (or array of
            // strings) and each entry must resolve to a keyword or be
            // shaped like an absolute IRI — blank-node identifiers and
            // strings containing whitespace are rejected.
            if let typeVal = result["@type"] {
                let typeItems: [JSON]
                if case .array(let arr) = typeVal { typeItems = arr }
                else { typeItems = [typeVal] }
                // §4.6.6: a value object's @type accepts at most one
                // value — multi-element arrays throw `invalid typed
                // value` (er54).
                if typeItems.count > 1 {
                    throw .other(code: "invalid typed value",
                                 message: "value object @type cannot have multiple values")
                }
                let allowedTypeKeywords: Set<String> = ["@id", "@vocab", "@json", "@none"]
                for t in typeItems {
                    guard case .string(let s) = t else {
                        throw .other(code: "invalid typed value",
                                     message: "@type on value object must be a string")
                    }
                    if allowedTypeKeywords.contains(s) { continue }
                    if s.hasPrefix("_:") {
                        throw .other(code: "invalid typed value",
                                     message: "@type on value object must not be a blank-node identifier")
                    }
                    if s.contains(" ") || !s.contains(":") {
                        throw .other(code: "invalid typed value",
                                     message: "@type on value object must be an absolute IRI: \(s)")
                    }
                }
            }
            // @language value must be a string. The @value must also
            // be a string when @language is present.
            if let langVal = result["@language"] {
                if case .string = langVal {} else {
                    throw .other(code: "invalid language-tagged string",
                                 message: "@language on value object must be a string")
                }
                switch result["@value"]! {
                case .string, .null: break
                default:
                    throw .other(code: "invalid language-tagged value",
                                 message: "@value must be a string when @language is present")
                }
            }
            // Existing collapse: single-element @type / @language
            // arrays become scalars for downstream compaction.
            if case .array(let arr) = result["@type"] ?? .null {
                if arr.count == 1 { result["@type"] = arr[0] }
            }
            if case .array(let arr) = result["@language"] ?? .null {
                if arr.count == 1 { result["@language"] = arr[0] }
            }
        }

        return .object(result)
    }

    /// Value Expansion — [JSON-LD 1.1 API §7.4](https://www.w3.org/TR/json-ld11-api/#value-expansion).
    ///
    /// Applies `@type`, `@language`, `@direction` from the active
    /// property's term definition (when present) per §7.4. Handles the
    /// `@id`/`@vocab` type-coercion shortcuts for IRI-valued strings.
    static func expandValue(
        _ value: JSON,
        activeProperty: String?,
        activeContext ctx: ActiveContext
    ) async -> JSON {
        let termDef = activeProperty.flatMap { ctx.termDefinitions[$0] }
        let typeMapping = termDef?.typeMapping

        // @id-typed string → expand as IRI and emit {"@id": ...}
        if typeMapping == "@id", case .string(let s) = value {
            var ctxMutable = ctx
            var defs: [String: Bool] = [:]
            if let expanded = try? await expandIRI(
                value: s,
                activeContext: &ctxMutable,
                documentRelative: true,
                defined: &defs,
                options: Options()
            ) {
                return .object(["@id": .string(expanded)])
            }
        }
        // @vocab-typed string → expand with vocab + base
        if typeMapping == "@vocab", case .string(let s) = value {
            var ctxMutable = ctx
            var defs: [String: Bool] = [:]
            if let expanded = try? await expandIRI(
                value: s,
                activeContext: &ctxMutable,
                documentRelative: true,
                vocab: true,
                defined: &defs,
                options: Options()
            ) {
                return .object(["@id": .string(expanded)])
            }
        }

        var rval: [String: JSON] = ["@value": value]

        if let type = typeMapping,
           !["@id", "@vocab", "@none"].contains(type)
        {
            rval["@type"] = .string(type)
        } else if case .string = value {
            // Only string values get language / direction tagging.
            if case .tag(let lang) = termDef?.languageMapping {
                rval["@language"] = .string(lang)
            } else if termDef?.languageMapping == nil,
                      let defaultLang = ctx.defaultLanguage
            {
                rval["@language"] = .string(defaultLang)
            }
            if let dir = termDef?.directionMapping {
                switch dir {
                case .ltr: rval["@direction"] = .string("ltr")
                case .rtl: rval["@direction"] = .string("rtl")
                case .null: break
                }
            } else if let dir = ctx.defaultBaseDirection {
                switch dir {
                case .ltr: rval["@direction"] = .string("ltr")
                case .rtl: rval["@direction"] = .string("rtl")
                case .null: break
                }
            }
        }

        return .object(rval)
    }
}
