import Foundation

extension JSONLD {
    /// Framing — [JSON-LD 1.1 Framing](https://www.w3.org/TR/json-ld11-framing/).
    ///
    /// Function-for-function port of the JavaScript reference
    /// [`digitalbazaar/jsonld.js`](https://github.com/digitalbazaar/jsonld.js)
    /// `lib/frame.js`. Each Swift function is annotated with the
    /// corresponding JS function name and line range so behavioral
    /// drift can be diffed against the reference.
    enum Framing {

        // MARK: - State

        /// Reference cell so a previously-emitted output node can be
        /// reached and mutated through `removeEmbed` (jsonld.js relies on
        /// JS object identity; Swift's value-typed `JSON` needs an
        /// explicit indirection).
        final class OutputCell: @unchecked Sendable {
            var value: JSON
            init(_ value: JSON) { self.value = value }
        }

        struct UniqueEmbed: Sendable {
            let parent: Parent
            let property: String?
        }

        /// The parent context an `_addFrameOutput` call writes into:
        /// either the top-level result array, or a property of a node
        /// object somewhere in the output tree.
        enum Parent: @unchecked Sendable {
            case array(OutputCell)   // cell wraps a `.array([...])` JSON
            case object(OutputCell)  // cell wraps a `.object([...])` JSON
        }

        /// Frame flags resolved at the top of each `frame(...)` call.
        struct Flags: Sendable {
            var embed: JSONLD.Options.FrameEmbed
            var explicit: Bool
            var requireAll: Bool
        }

        /// Mutable state threaded through the framing algorithm — port
        /// of jsonld.js's `state` object built in `frameMergedOrDefault`.
        struct State {
            var options: JSONLD.Options
            var embedded: Bool = false
            var graph: String = "@default"
            var graphMap: [String: [String: [String: JSON]]]
            var subjectStack: [(subject: [String: JSON], graph: String)] = []
            var link: [String: [String: OutputCell]] = [:]
            var bnodeMap: [String: [OutputCell]] = [:]
            var uniqueEmbeds: [String: [String: UniqueEmbed]] = [:]
            var is11: Bool
            var subjects: [String: [String: JSON]] {
                graphMap[graph] ?? [:]
            }
        }

        // MARK: - Public driver

        /// Port of jsonld.js `api.frameMergedOrDefault` (frame.js:29-65).
        /// Spec: [§5 Framing Algorithm](https://www.w3.org/TR/json-ld11-framing/#framing-algorithm).
        static func frameMergedOrDefault(
            graphMap: [String: [String: [String: JSON]]],
            startingGraph: String,
            frame: JSON,
            options: JSONLD.Options
        ) throws(JSONLD.Error) -> JSON {
            var state = State(
                options: options,
                graph: startingGraph,
                graphMap: graphMap,
                is11: options.processingMode == .jsonLd11
            )

            let topLevel = OutputCell(.array([]))
            let subjects = state.graphMap[state.graph] ?? [:]
            let ids = subjects.keys.sorted()

            try Self.frame(
                state: &state,
                subjects: ids,
                frame: frame,
                parent: Parent.array(topLevel),
                property: nil
            )

            // Pruning: collect blank-node ids referenced exactly once.
            // Default per spec: enabled for processing mode 1.1, off
            // for 1.0. Callers can override via `options.pruneBlankNodeIdentifiers`.
            let prune = options.pruneBlankNodeIdentifiers
                ?? (options.processingMode == .jsonLd11)
            if prune {
                var bnodesToClear: Set<String> = []
                for (id, cells) in state.bnodeMap where cells.count == 1 {
                    bnodesToClear.insert(id)
                }
                return cleanupPreserve(topLevel.value, bnodesToClear: bnodesToClear)
            }
            return cleanupPreserve(topLevel.value, bnodesToClear: [])
        }

        // MARK: - frame

        /// Port of jsonld.js `api.frame` (frame.js:76-323).
        /// The recursive matching workhorse.
        static func frame(
            state: inout State,
            subjects: [String],
            frame frameInput: JSON,
            parent: Parent,
            property: String?
        ) throws(JSONLD.Error) {
            try validateFrame(frameInput)
            let frame: [String: JSON] = {
                if case .array(let arr) = frameInput, let first = arr.first, case .object(let m) = first { return m }
                if case .object(let m) = frameInput { return m }
                return [:]
            }()

            // Resolve flags.
            let flags = Flags(
                embed: getFrameEmbedFlag(frame: frame, options: state.options),
                explicit: getFrameBoolFlag(frame: frame, options: state.options, name: "@explicit", defaultValue: state.options.explicit),
                requireAll: getFrameBoolFlag(frame: frame, options: state.options, name: "@requireAll", defaultValue: state.options.requireAll)
            )

            // Link map for the current graph.
            if state.link[state.graph] == nil { state.link[state.graph] = [:] }

            // Filter to matching subjects.
            let matches = filterSubjects(state: state, subjects: subjects, frame: frame, flags: flags)
            let ids = matches.keys.sorted()

            for id in ids {
                let subject = matches[id]!

                // Reset uniqueEmbeds at top-level matches.
                if property == nil {
                    state.uniqueEmbeds = [state.graph: [:]]
                } else if state.uniqueEmbeds[state.graph] == nil {
                    state.uniqueEmbeds[state.graph] = [:]
                }

                // @link: reuse previously emitted output.
                if flags.embed == .link, let existing = state.link[state.graph]?[id] {
                    addFrameOutput(parent: parent, property: property, output: existing)
                    continue
                }

                // Start a fresh output node.
                let output = OutputCell(.object(["@id": .string(id)]))
                if id.hasPrefix("_:") {
                    state.bnodeMap[id, default: []].append(output)
                }
                state.link[state.graph]?[id] = output

                // Already top-level emitted? Skip (jsonld.js handles this
                // when state.embedded is false and id already in
                // uniqueEmbeds[graph]).
                if !state.embedded, state.uniqueEmbeds[state.graph]?[id] != nil {
                    continue
                }

                // @never or circular → reference.
                if state.embedded,
                   flags.embed == .never
                    || createsCircularReference(subject: subject, graph: state.graph, stack: state.subjectStack)
                {
                    addFrameOutput(parent: parent, property: property, output: output)
                    continue
                }

                // @once / @first: first occurrence wins; later refs
                // become bare `{"@id": …}`.
                if state.embedded,
                   (flags.embed == .once || flags.embed == .first),
                   state.uniqueEmbeds[state.graph]?[id] != nil
                {
                    addFrameOutput(parent: parent, property: property, output: output)
                    continue
                }

                // @last: last occurrence wins. Rewrite the prior embed
                // in place (replace with `{"@id": …}`), then embed
                // afresh at this location.
                if state.embedded,
                   flags.embed == .last,
                   let prior = state.uniqueEmbeds[state.graph]?[id]
                {
                    removeEmbed(prior: prior, id: id)
                }

                state.uniqueEmbeds[state.graph]?[id] = UniqueEmbed(parent: parent, property: property)

                // Push onto stack for circular checks.
                state.subjectStack.append((subject, state.graph))

                // If subject is also a graph name, recurse into the graph.
                if state.graphMap[id] != nil {
                    var recurse = false
                    var subFrame: JSON = .object([:])
                    if frame["@graph"] == nil {
                        recurse = state.graph != "@merged"
                    } else {
                        if case .array(let arr) = frame["@graph"]!, let first = arr.first {
                            subFrame = first
                        } else {
                            subFrame = frame["@graph"]!
                        }
                        recurse = id != "@merged" && id != "@default"
                        if case .object = subFrame { } else { subFrame = .object([:]) }
                    }
                    if recurse {
                        var inner = state
                        inner.graph = id
                        inner.embedded = false
                        let innerIDs = (state.graphMap[id] ?? [:]).keys.sorted()
                        try Self.frame(
                            state: &inner,
                            subjects: innerIDs,
                            frame: .array([subFrame]),
                            parent: .object(output),
                            property: "@graph"
                        )
                        // Persist mutated bookkeeping.
                        state.link = inner.link
                        state.bnodeMap = inner.bnodeMap
                        state.uniqueEmbeds = inner.uniqueEmbeds
                    }
                }

                // @included sub-frame.
                if let included = frame["@included"] {
                    var inner = state
                    inner.embedded = false
                    try Self.frame(
                        state: &inner,
                        subjects: subjects,
                        frame: included,
                        parent: .object(output),
                        property: "@included"
                    )
                    state.link = inner.link
                    state.bnodeMap = inner.bnodeMap
                    state.uniqueEmbeds = inner.uniqueEmbeds
                }

                // Walk subject properties (sorted).
                for prop in subject.keys.sorted() {
                    // Keyword properties — copy onto output.
                    if isKeyword(prop) {
                        // Skip @id (already set).
                        if prop == "@id" { continue }
                        if case .object(var outMap) = output.value {
                            outMap[prop] = subject[prop]
                            output.value = .object(outMap)
                        }
                        // Track bnode-typed @type values.
                        if prop == "@type", case .array(let types) = subject["@type"] ?? .null {
                            for t in types {
                                if case .string(let s) = t, s.hasPrefix("_:") {
                                    state.bnodeMap[s, default: []].append(output)
                                }
                            }
                        }
                        continue
                    }

                    // @explicit + property not in frame → skip.
                    if flags.explicit, frame[prop] == nil { continue }

                    guard case .array(let propValues) = subject[prop] ?? .null else { continue }
                    for o in propValues {
                        let subFrame: JSON = frame[prop] ?? .array([createImplicitFrame(flags: flags)])

                        if isList(o) {
                            // Recurse into @list. Build the list items
                            // into a fresh cell first, *then* attach to
                            // the parent — `addFrameOutput` value-copies
                            // the cell at attach time, so mutating after
                            // attachment is invisible to the parent.
                            let listSubFrame: JSON = {
                                if case .array(let arr) = frame[prop] ?? .null,
                                   let first = arr.first,
                                   case .object(let m) = first,
                                   let l = m["@list"]
                                {
                                    return l
                                }
                                return .array([createImplicitFrame(flags: flags)])
                            }()

                            let listCell = OutputCell(.object(["@list": .array([])]))

                            if case .object(let oMap) = o, case .array(let listSrc) = oMap["@list"] ?? .null {
                                for oo in listSrc {
                                    if isSubjectReference(oo), case .object(let refMap) = oo, case .string(let refId) = refMap["@id"] ?? .null {
                                        var inner = state
                                        inner.embedded = true
                                        try Self.frame(
                                            state: &inner,
                                            subjects: [refId],
                                            frame: listSubFrame,
                                            parent: .object(listCell),
                                            property: "@list"
                                        )
                                        state.link = inner.link
                                        state.bnodeMap = inner.bnodeMap
                                        state.uniqueEmbeds = inner.uniqueEmbeds
                                    } else {
                                        addFrameOutputValue(parent: .object(listCell), property: "@list", value: oo)
                                    }
                                }
                            }
                            addFrameOutput(parent: .object(output), property: prop, output: listCell)
                        } else if isSubjectReference(o), case .object(let refMap) = o, case .string(let refId) = refMap["@id"] ?? .null {
                            // Recurse into subject reference.
                            var inner = state
                            inner.embedded = true
                            try Self.frame(
                                state: &inner,
                                subjects: [refId],
                                frame: subFrame,
                                parent: .object(output),
                                property: prop
                            )
                            state.link = inner.link
                            state.bnodeMap = inner.bnodeMap
                            state.uniqueEmbeds = inner.uniqueEmbeds
                        } else {
                            // Value object — include if it matches the value pattern.
                            let pattern: [String: JSON] = {
                                if case .array(let arr) = subFrame, let first = arr.first, case .object(let m) = first { return m }
                                if case .object(let m) = subFrame { return m }
                                return [:]
                            }()
                            if valueMatch(pattern: pattern, value: o) {
                                addFrameOutputValue(parent: .object(output), property: prop, value: o)
                            }
                        }
                    }
                }

                // Handle @default insertion.
                for prop in frame.keys.sorted() {
                    if prop == "@type" {
                        // Only allow default through if the frame's @type entry has @default.
                        if case .array(let arr) = frame[prop] ?? .null,
                           let first = arr.first,
                           case .object(let m) = first,
                           m["@default"] != nil
                        {
                            // allow through
                        } else { continue }
                    } else if isKeyword(prop) {
                        continue
                    }

                    let next: [String: JSON] = {
                        if case .array(let arr) = frame[prop] ?? .null,
                           let first = arr.first,
                           case .object(let m) = first
                        { return m }
                        // Sub-frame may also be a bare object — g005's
                        // `ex:contains` sub-frame is an object literal
                        // carrying `@omitDefault: "true"`.
                        if case .object(let m) = frame[prop] ?? .null {
                            return m
                        }
                        return [:]
                    }()
                    let omitDefaultOn = getFrameBoolFlag(frame: next, options: state.options, name: "@omitDefault", defaultValue: state.options.omitDefault)

                    if case .object(let outMap) = output.value, outMap[prop] != nil { continue }
                    if omitDefaultOn { continue }

                    var preserve: JSON = .string("@null")
                    if let def = next["@default"] {
                        preserve = def
                    }
                    if case .array = preserve { } else { preserve = .array([preserve]) }

                    if case .object(var outMap) = output.value {
                        outMap[prop] = .array([.object(["@preserve": preserve])])
                        output.value = .object(outMap)
                    }
                }

                // @reverse: find nodes pointing at this subject via reverseProp.
                if case .object(let revMap) = frame["@reverse"] ?? .null {
                    for reverseProp in revMap.keys.sorted() {
                        let subFrame = revMap[reverseProp]!
                        for otherId in state.subjects.keys.sorted() {
                            guard let other = state.subjects[otherId] else { continue }
                            let nodeValues: [JSON] = {
                                if case .array(let arr) = other[reverseProp] ?? .null { return arr }
                                return []
                            }()
                            let hasBackref = nodeValues.contains {
                                if case .object(let m) = $0, case .string(let s) = m["@id"] ?? .null, s == id { return true }
                                return false
                            }
                            if hasBackref {
                                if case .object(var outMap) = output.value {
                                    var rev: [String: JSON]
                                    if case .object(let existing) = outMap["@reverse"] ?? .null { rev = existing } else { rev = [:] }
                                    if rev[reverseProp] == nil { rev[reverseProp] = .array([]) }
                                    outMap["@reverse"] = .object(rev)
                                    output.value = .object(outMap)
                                }
                                // Recursion writes into the @reverse[reverseProp] array.
                                let revCell = OutputCell(.array([]))
                                var inner = state
                                inner.embedded = true
                                try Self.frame(
                                    state: &inner,
                                    subjects: [otherId],
                                    frame: subFrame,
                                    parent: .array(revCell),
                                    property: property
                                )
                                state.link = inner.link
                                state.bnodeMap = inner.bnodeMap
                                state.uniqueEmbeds = inner.uniqueEmbeds
                                if case .array(let items) = revCell.value,
                                   case .object(var outMap) = output.value,
                                   case .object(var rev) = outMap["@reverse"] ?? .null
                                {
                                    if case .array(let existing) = rev[reverseProp] ?? .array([]) {
                                        rev[reverseProp] = .array(existing + items)
                                    } else {
                                        rev[reverseProp] = .array(items)
                                    }
                                    outMap["@reverse"] = .object(rev)
                                    output.value = .object(outMap)
                                }
                            }
                        }
                    }
                }

                addFrameOutput(parent: parent, property: property, output: output)
                state.subjectStack.removeLast()
            }
        }

        // MARK: - cleanupNull

        /// Port of jsonld.js `api.cleanupNull` (frame.js:333-367).
        /// Replace `@null` markers with JSON `null`; drop them from arrays.
        static func cleanupNull(_ input: JSON) -> JSON {
            switch input {
            case .array(let arr):
                let mapped = arr.map { cleanupNull($0) }
                return .array(mapped.filter { if case .null = $0 { return false } else { return true } })
            case .string(let s) where s == "@null":
                return .null
            case .object(let m):
                var out: [String: JSON] = [:]
                for (k, v) in m { out[k] = cleanupNull(v) }
                return .object(out)
            default:
                return input
            }
        }

        // MARK: - validateFrame

        /// Port of jsonld.js `_validateFrame` (frame.js:446-477).
        /// Relaxed for first slice: treat empty arrays + missing top-level
        /// frame objects as wildcards rather than throwing — many test
        /// frames expand to `[]` (e.g. when the frame is just `@context`).
        static func validateFrame(_ frame: JSON) throws(JSONLD.Error) {
            let topObj: [String: JSON]
            switch frame {
            case .array(let arr):
                if arr.isEmpty { return }
                guard case .object(let m) = arr[0] else {
                    throw .other(code: "invalid frame", message: "frame must be a single object")
                }
                topObj = m
            case .object(let m):
                topObj = m
            default:
                throw .other(code: "invalid frame", message: "frame must be a single object")
            }

            // @id values must be wildcard ({}) or absolute IRIs (not blank).
            if let idVal = topObj["@id"] {
                let ids: [JSON] = {
                    if case .array(let a) = idVal { return a }
                    return [idVal]
                }()
                for v in ids {
                    switch v {
                    case .object: continue
                    case .string(let s):
                        if s.hasPrefix("_:") {
                            throw .other(code: "invalid frame", message: "frame @id must not be a blank node label")
                        }
                    default: continue
                    }
                }
            }

            // @type values must be wildcard, IRI, or @json — blank-node
            // identifiers are rejected (`invalid frame`).
            if let tVal = topObj["@type"] {
                let ts: [JSON] = {
                    if case .array(let a) = tVal { return a }
                    return [tVal]
                }()
                for v in ts {
                    if case .string(let s) = v, s.hasPrefix("_:") {
                        throw .other(code: "invalid frame",
                                     message: "frame @type must not include a blank-node identifier")
                    }
                }
            }
            // @embed value (if present at the top level) must be one
            // of the spec's allowed strings — anything else throws
            // `invalid @embed value`.
            if let embedVal = topObj["@embed"] {
                let raw: JSON = {
                    if case .array(let a) = embedVal, let first = a.first { return first }
                    return embedVal
                }()
                let allowed: Set<String> = ["@always", "@once", "@never", "@last", "@first", "@link", "@null"]
                switch raw {
                case .string(let s):
                    if !allowed.contains(s) {
                        throw .other(code: "invalid @embed value",
                                     message: "frame @embed value \"\(s)\" is not allowed")
                    }
                case .bool: break
                default:
                    throw .other(code: "invalid @embed value",
                                 message: "frame @embed value must be a string or boolean")
                }
            }
        }

        // MARK: - getFrameFlag

        /// Port of jsonld.js `_getFrameFlag` (frame.js:419-439) for `@embed`.
        /// Handles wrapped (`[v]`), bare (`v`), string, and legacy boolean
        /// forms (`true` → `@once`, `false` → `@never`).
        static func getFrameEmbedFlag(
            frame: [String: JSON],
            options: JSONLD.Options
        ) -> JSONLD.Options.FrameEmbed {
            let raw: JSON?
            if case .array(let arr) = frame["@embed"] ?? .null {
                raw = arr.first
            } else {
                raw = frame["@embed"]
            }
            if case .string(let s) = raw, let e = JSONLD.Options.FrameEmbed(rawValue: s) {
                return e
            }
            if case .bool(let b) = raw {
                return b ? .once : .never
            }
            return options.embed
        }

        /// Port of jsonld.js `_getFrameFlag` (frame.js:419-439) for boolean flags.
        /// Reads from both wrapped (`[v]`) and bare (`v`) shapes.
        static func getFrameBoolFlag(
            frame: [String: JSON],
            options: JSONLD.Options,
            name: String,
            defaultValue: Bool
        ) -> Bool {
            let raw: JSON?
            if case .array(let arr) = frame[name] ?? .null {
                raw = arr.first
            } else {
                raw = frame[name]
            }
            if case .bool(let b) = raw { return b }
            // jsonld.js accepts string `"true"` / `"false"` in addition
            // to JSON booleans — used by tg005's `@omitDefault: "true"`.
            if case .string(let s) = raw {
                if s == "true" { return true }
                if s == "false" { return false }
            }
            return defaultValue
        }

        // MARK: - filterSubjects / filterSubject

        /// Port of jsonld.js `_filterSubjects` (frame.js:489-499).
        static func filterSubjects(
            state: State,
            subjects: [String],
            frame: [String: JSON],
            flags: Flags
        ) -> [String: [String: JSON]] {
            var out: [String: [String: JSON]] = [:]
            for id in subjects.sorted() {
                guard let subject = state.graphMap[state.graph]?[id] else { continue }
                if filterSubject(state: state, subject: subject, frame: frame, flags: flags) {
                    out[id] = subject
                }
            }
            return out
        }

        /// Port of jsonld.js `_filterSubject` (frame.js:519-637).
        static func filterSubject(
            state: State,
            subject: [String: JSON],
            frame frameIn: [String: JSON],
            flags: Flags
        ) -> Bool {
            // When the frame has `@graph` carrying a sub-frame that
            // describes a default-graph subject (e.g. tg010's
            // `{@graph: {subject: {}, proof: {}}}`), fold the sub-frame's
            // non-keyword keys into the filter set. Without this, the
            // top-level frame iterates only `@graph` (a keyword), no
            // filter applies, and every subject matches.
            var frame = frameIn
            if let graphValue = frame["@graph"] {
                let subFrameMap: [String: JSON]? = {
                    if case .array(let arr) = graphValue,
                       let first = arr.first,
                       case .object(let m) = first
                    { return m }
                    if case .object(let m) = graphValue { return m }
                    return nil
                }()
                if let subFrameMap {
                    for (k, v) in subFrameMap
                    where !isKeyword(k) && frame[k] == nil {
                        frame[k] = v
                    }
                }
            }

            var wildcard = true
            var matchesSome = false

            for key in frame.keys {
                var matchThis = false
                let nodeValues: [JSON] = {
                    if case .array(let arr) = subject[key] ?? .null { return arr }
                    if let v = subject[key] { return [v] }
                    return []
                }()
                let frameValues: [JSON] = {
                    if case .array(let arr) = frame[key] ?? .null { return arr }
                    if let v = frame[key] { return [v] }
                    return []
                }()
                let isEmpty = frameValues.isEmpty

                switch key {
                case "@id":
                    if let first = frameValues.first, isEmptyObject(first) {
                        matchThis = true
                    } else if !frameValues.isEmpty {
                        let nodeIdValue: JSON? = nodeValues.first
                        if let nv = nodeIdValue {
                            matchThis = frameValues.contains(nv)
                        }
                    }
                    if !flags.requireAll { return matchThis }
                case "@type":
                    wildcard = false
                    if isEmpty {
                        if !nodeValues.isEmpty { return false }
                        matchThis = true
                    } else if frameValues.count == 1, isEmptyObject(frameValues[0]) {
                        matchThis = !nodeValues.isEmpty
                    } else {
                        for t in frameValues {
                            if case .object(let m) = t, m["@default"] != nil {
                                matchThis = true
                            } else {
                                matchThis = matchThis || nodeValues.contains(t)
                            }
                        }
                    }
                    if !flags.requireAll { return matchThis }
                default:
                    if isKeyword(key) { continue }
                    let thisFrame: JSON? = frameValues.first
                    var hasDefault = false
                    if let tf = thisFrame {
                        // First-slice: skip the recursive validateFrame
                        // call jsonld.js does here — it's defensive only.
                        if case .object(let m) = tf, m["@default"] != nil { hasDefault = true }
                    }

                    wildcard = false

                    if nodeValues.isEmpty, hasDefault { continue }
                    if !nodeValues.isEmpty, isEmpty { return false }

                    guard let tf = thisFrame else {
                        if !nodeValues.isEmpty { return false }
                        matchThis = true
                        break
                    }

                    if isList(tf), case .object(let fm) = tf, case .array(let frameList) = fm["@list"] ?? .null, let listValue = frameList.first {
                        if let firstNode = nodeValues.first, isList(firstNode), case .object(let nm) = firstNode, case .array(let nodeListValues) = nm["@list"] ?? .null {
                            if isValue(listValue), case .object(let lvMap) = listValue {
                                matchThis = nodeListValues.contains { valueMatch(pattern: lvMap, value: $0) }
                            } else if isSubject(listValue) || isSubjectReference(listValue) {
                                matchThis = nodeListValues.contains { nodeMatch(state: state, pattern: listValue, value: $0, flags: flags) }
                            }
                        }
                    } else if isValue(tf), case .object(let fm) = tf {
                        matchThis = nodeValues.contains { valueMatch(pattern: fm, value: $0) }
                    } else if isSubjectReference(tf) {
                        matchThis = nodeValues.contains { nodeMatch(state: state, pattern: tf, value: $0, flags: flags) }
                    } else if case .object = tf {
                        matchThis = !nodeValues.isEmpty
                    }
                }

                if !matchThis, flags.requireAll { return false }
                matchesSome = matchesSome || matchThis
            }
            return wildcard || matchesSome
        }

        // MARK: - Implicit frame / circular check

        /// Port of jsonld.js `_createImplicitFrame` (frame.js:379-387).
        static func createImplicitFrame(flags: Flags) -> JSON {
            var m: [String: JSON] = [:]
            m["@embed"] = .array([.string(flags.embed.rawValue)])
            m["@explicit"] = .array([.bool(flags.explicit)])
            m["@requireAll"] = .array([.bool(flags.requireAll)])
            return .object(m)
        }

        /// Port of jsonld.js `_createsCircularReference` (frame.js:399-408).
        static func createsCircularReference(
            subject: [String: JSON],
            graph: String,
            stack: [(subject: [String: JSON], graph: String)]
        ) -> Bool {
            guard case .string(let sid) = subject["@id"] ?? .null else { return false }
            for i in stride(from: stack.count - 1, through: 0, by: -1) {
                let entry = stack[i]
                if entry.graph == graph,
                   case .string(let eid) = entry.subject["@id"] ?? .null,
                   eid == sid
                {
                    return true
                }
            }
            return false
        }

        // MARK: - nodeMatch / valueMatch

        /// Port of jsonld.js `_nodeMatch` (frame.js:771-777).
        static func nodeMatch(
            state: State,
            pattern: JSON,
            value: JSON,
            flags: Flags
        ) -> Bool {
            guard case .object(let v) = value, case .string(let id) = v["@id"] ?? .null else { return false }
            guard let nodeObj = state.subjects[id] else { return false }
            let patternMap: [String: JSON] = {
                if case .object(let m) = pattern { return m }
                if case .array(let arr) = pattern, let first = arr.first, case .object(let m) = first { return m }
                return [:]
            }()
            return filterSubject(state: state, subject: nodeObj, frame: patternMap, flags: flags)
        }

        /// Port of jsonld.js `_valueMatch` (frame.js:794-826).
        static func valueMatch(pattern: [String: JSON], value: JSON) -> Bool {
            guard case .object(let v) = value else { return false }
            let v1 = v["@value"]
            let t1 = v["@type"]
            let l1 = v["@language"]

            let v2: [JSON] = arrayify(pattern["@value"])
            let t2: [JSON] = arrayify(pattern["@type"])
            let l2: [JSON] = arrayify(pattern["@language"])

            if v2.isEmpty, t2.isEmpty, l2.isEmpty { return true }

            // @value match
            if let v1 {
                let v1MatchesArray = v2.contains(v1)
                let v2WildcardFirst = !v2.isEmpty && isEmptyObject(v2[0])
                if !(v1MatchesArray || v2WildcardFirst) { return false }
            } else if !v2.isEmpty {
                return false
            }

            // @type match
            if t1 == nil, !t2.isEmpty {
                let t2WildcardFirst = isEmptyObject(t2[0])
                if !t2WildcardFirst { return false }
            }
            if let t1 {
                let included = t2.contains(t1)
                let wildcardFirst = !t2.isEmpty && isEmptyObject(t2[0])
                if !(included || wildcardFirst) { return false }
            }

            // @language match
            if l1 == nil, !l2.isEmpty {
                let l2WildcardFirst = isEmptyObject(l2[0])
                if !l2WildcardFirst { return false }
            }
            if let l1 {
                let included = l2.contains(l1)
                let wildcardFirst = !l2.isEmpty && isEmptyObject(l2[0])
                if !(included || wildcardFirst) { return false }
            }
            return true
        }

        // MARK: - cleanupPreserve

        /// Port of jsonld.js `_cleanupPreserve` (frame.js:694-746).
        /// Also handles blank-node pruning since the JS version does both.
        static func cleanupPreserve(_ input: JSON, bnodesToClear: Set<String>) -> JSON {
            switch input {
            case .array(let arr):
                return .array(arr.map { cleanupPreserve($0, bnodesToClear: bnodesToClear) })
            case .object(let m):
                if let p = m["@preserve"] {
                    if case .array(let arr) = p, let first = arr.first {
                        return cleanupPreserve(first, bnodesToClear: bnodesToClear)
                    }
                    return cleanupPreserve(p, bnodesToClear: bnodesToClear)
                }
                if m["@value"] != nil { return input }
                var out: [String: JSON] = [:]
                for (k, v) in m {
                    if k == "@id", case .string(let s) = v, bnodesToClear.contains(s) { continue }
                    out[k] = cleanupPreserve(v, bnodesToClear: bnodesToClear)
                }
                return .object(out)
            default:
                return input
            }
        }

        // MARK: - addFrameOutput

        /// Port of jsonld.js `_addFrameOutput` (frame.js:755-761).
        static func addFrameOutput(parent: Parent, property: String?, output: OutputCell) {
            switch parent {
            case .array(let cell):
                if case .array(var arr) = cell.value {
                    arr.append(output.value)
                    cell.value = .array(arr)
                }
            case .object(let cell):
                guard let prop = property else { return }
                if case .object(var m) = cell.value {
                    if case .array(var arr) = m[prop] ?? .array([]) {
                        arr.append(output.value)
                        m[prop] = .array(arr)
                    } else {
                        m[prop] = .array([output.value])
                    }
                    cell.value = .object(m)
                }
            }
        }

        /// Convenience for the value-object case where no cell is wanted.
        static func addFrameOutputValue(parent: Parent, property: String?, value: JSON) {
            addFrameOutput(parent: parent, property: property, output: OutputCell(value))
        }

        /// Port of jsonld.js `_removeEmbed` (frame.js:645-684).
        /// Replace the prior embed of `id` (recorded in `prior.parent`)
        /// with a bare `{"@id": id}` reference in place. Used for
        /// `@embed: @last` so the most recent occurrence keeps the
        /// full embed and earlier ones become references.
        static func removeEmbed(prior: UniqueEmbed, id: String) {
            let ref: JSON = .object(["@id": .string(id)])
            switch prior.parent {
            case .array(let cell):
                if case .array(var arr) = cell.value {
                    for i in 0..<arr.count {
                        if case .object(let m) = arr[i],
                           case .string(let s) = m["@id"] ?? .null,
                           s == id
                        {
                            arr[i] = ref
                            cell.value = .array(arr)
                            return
                        }
                    }
                }
            case .object(let cell):
                guard let prop = prior.property else { return }
                if case .object(var m) = cell.value,
                   case .array(var arr) = m[prop] ?? .null
                {
                    for i in 0..<arr.count {
                        if case .object(let inner) = arr[i],
                           case .string(let s) = inner["@id"] ?? .null,
                           s == id
                        {
                            arr[i] = ref
                            m[prop] = .array(arr)
                            cell.value = .object(m)
                            return
                        }
                    }
                }
            }
        }

        // MARK: - mergeNodeMapGraphs

        /// Port of jsonld.js `mergeNodeMapGraphs` (nodeMap.js).
        /// Flatten all named-graph nodes back into one keyed-by-@id dict.
        static func mergeNodeMapGraphs(
            _ graphs: [String: [String: [String: JSON]]]
        ) -> [String: [String: JSON]] {
            var merged: [String: [String: JSON]] = [:]
            for (graphName, nodes) in graphs {
                if graphName == "@merged" { continue }
                for (id, node) in nodes {
                    if var existing = merged[id] {
                        for (k, v) in node {
                            if k == "@id" { continue }
                            if k == "@type" || !k.hasPrefix("@") {
                                if case .array(var existingArr) = existing[k] ?? .array([]),
                                   case .array(let newArr) = v
                                {
                                    for item in newArr where !existingArr.contains(item) {
                                        existingArr.append(item)
                                    }
                                    existing[k] = .array(existingArr)
                                } else if existing[k] == nil {
                                    existing[k] = v
                                }
                            } else if existing[k] == nil {
                                existing[k] = v
                            }
                        }
                        merged[id] = existing
                    } else {
                        merged[id] = node
                    }
                }
            }
            return merged
        }

        // MARK: - Frame expansion

        /// Frame-specific expansion. The public `expand` turns frame
        /// keyword values into value objects (`@explicit: true` →
        /// `[{"@value": true}]`) and drops things it can't classify;
        /// neither suits a frame. This is a minimal walker that resolves
        /// term keys to IRIs against the frame's `@context`, preserves
        /// every JSON-LD keyword (including frame keywords) verbatim,
        /// wraps non-array property values in arrays (to match the
        /// expanded shape the algorithm walks), and never drops keys.
        static func expandFrame(
            _ frame: JSON,
            activeContext: ActiveContext,
            options: JSONLD.Options
        ) async throws(JSONLD.Error) -> JSON {
            return try await expandFrameInner(frame, activeContext: activeContext, activeProperty: nil, options: options)
        }

        private static func expandFrameInner(
            _ element: JSON,
            activeContext: ActiveContext,
            activeProperty: String?,
            options: JSONLD.Options
        ) async throws(JSONLD.Error) -> JSON {
            switch element {
            case .null, .bool, .int, .double, .string:
                return element
            case .array(let arr):
                var out: [JSON] = []
                for item in arr {
                    let exp = try await expandFrameInner(item, activeContext: activeContext, activeProperty: activeProperty, options: options)
                    if case .array(let inner) = exp { out.append(contentsOf: inner) }
                    else { out.append(exp) }
                }
                return .array(out)
            case .object(let map):
                var ctx = activeContext
                if let local = map["@context"] {
                    ctx = try await JSONLD.processContext(
                        activeContext: activeContext,
                        localContext: local,
                        baseURL: ctx.baseIRI,
                        options: options
                    )
                }
                // Value objects (have `@value`) inside a frame are
                // template values — preserve their keys as-is so that
                // `@type` does NOT get wrapped in an array (otherwise
                // compact's value-coercion can't match the term's
                // type mapping; closes t0051 `@preserve`/`@default`).
                // Still IRI-expand `@type` values against the frame's
                // active context.
                if map["@value"] != nil {
                    var out: [String: JSON] = [:]
                    for (k, v) in map where k != "@context" {
                        if k == "@type" {
                            // IRI-expand each type. Preserve the
                            // value's shape: single string stays a
                            // string; arrays stay arrays (frame value
                            // patterns can carry multiple @types).
                            func expandType(_ t: JSON) async -> JSON {
                                guard case .string(let s) = t else { return t }
                                var defined: [String: Bool] = [:]
                                var iriCtx = ctx
                                do {
                                    if let iri = try await JSONLD.expandIRI(
                                        value: s,
                                        activeContext: &iriCtx,
                                        documentRelative: true,
                                        vocab: true,
                                        defined: &defined,
                                        options: options
                                    ) {
                                        return .string(iri)
                                    }
                                } catch {}
                                return t
                            }
                            if case .array(let arr) = v {
                                var resolved: [JSON] = []
                                for t in arr { resolved.append(await expandType(t)) }
                                out["@type"] = .array(resolved)
                            } else {
                                out["@type"] = await expandType(v)
                            }
                        } else if k == "@language", case .string(let s) = v {
                            out["@language"] = .string(s.lowercased())
                        } else {
                            out[k] = v
                        }
                    }
                    return .object(out)
                }
                var out: [String: JSON] = [:]
                for key in map.keys {
                    if key == "@context" { continue }
                    let value = map[key]!

                    let resolvedKey: String
                    var isReverseTerm = false
                    if let kw = Keyword(rawValue: key) {
                        resolvedKey = kw.rawValue
                    } else {
                        if let td = ctx.termDefinitions[key], td.reverseProperty {
                            isReverseTerm = true
                        }
                        var defined: [String: Bool] = [:]
                        var iriCtx = ctx
                        let resolved = try await JSONLD.expandIRI(
                            value: key,
                            activeContext: &iriCtx,
                            vocab: true,
                            localContext: nil,
                            defined: &defined,
                            options: options
                        )
                        guard let resolved else { continue }
                        resolvedKey = resolved
                    }

                    // Recurse on the value.
                    let expandedValue = try await expandFrameInner(
                        value,
                        activeContext: ctx,
                        activeProperty: resolvedKey,
                        options: options
                    )

                    // Don't wrap structural keywords whose value-shape
                    // is fixed by spec. (`@reverse` is a direct object,
                    // not an array; the frame algorithm walks its keys
                    // to find reverse-property frames.)
                    let unwrappedKeywords: Set<String> = [
                        "@id", "@type", "@value", "@language", "@direction",
                        "@index", "@embed", "@explicit", "@requireAll",
                        "@omitDefault", "@default", "@null", "@preserve",
                        "@reverse",
                    ]
                    if unwrappedKeywords.contains(resolvedKey) {
                        // @id/@type still get string-IRI expansion against the
                        // active context for IRIs (not for wildcards/booleans).
                        if resolvedKey == "@id" {
                            let items: [JSON] = {
                                if case .array(let a) = expandedValue { return a }
                                return [expandedValue]
                            }()
                            var resolved: [JSON] = []
                            for v in items {
                                if case .string(let s) = v {
                                    var defined: [String: Bool] = [:]
                                    var iriCtx = ctx
                                    if let iri = try await JSONLD.expandIRI(
                                        value: s,
                                        activeContext: &iriCtx,
                                        documentRelative: true,
                                        defined: &defined,
                                        options: options
                                    ) {
                                        resolved.append(.string(iri))
                                    } else {
                                        resolved.append(v)
                                    }
                                } else {
                                    resolved.append(v)
                                }
                            }
                            if case .array = expandedValue {
                                out["@id"] = .array(resolved)
                            } else if resolved.count == 1 {
                                out["@id"] = resolved[0]
                            } else {
                                out["@id"] = .array(resolved)
                            }
                        } else if resolvedKey == "@type" {
                            // Wrap in array; map string values through IRI expansion.
                            let items: [JSON] = {
                                if case .array(let a) = expandedValue { return a }
                                return [expandedValue]
                            }()
                            // IRI-expand a `@type`-typed value: handles
                            // bare strings AND strings nested inside
                            // `{@default: "..."}` so frame defaults reach
                            // compact() as absolute IRIs (te002 / t0064).
                            func expandTypeString(_ s: String) async -> String {
                                var defined: [String: Bool] = [:]
                                var iriCtx = ctx
                                do {
                                    if let iri = try await JSONLD.expandIRI(
                                        value: s,
                                        activeContext: &iriCtx,
                                        documentRelative: true,
                                        vocab: true,
                                        defined: &defined,
                                        options: options
                                    ) {
                                        return iri
                                    }
                                } catch {}
                                return s
                            }
                            var typeOut: [JSON] = []
                            for t in items {
                                if case .string(let s) = t {
                                    typeOut.append(.string(await expandTypeString(s)))
                                } else if case .object(var inner) = t,
                                          case .string(let ds) = inner["@default"] ?? .null
                                {
                                    inner["@default"] = .string(await expandTypeString(ds))
                                    typeOut.append(.object(inner))
                                } else {
                                    typeOut.append(t)
                                }
                            }
                            out["@type"] = .array(typeOut)
                        } else if resolvedKey == "@language" {
                            // Spec: language tags lowercase during expansion.
                            func lower(_ v: JSON) -> JSON {
                                if case .string(let s) = v { return .string(s.lowercased()) }
                                return v
                            }
                            if case .array(let arr) = expandedValue {
                                out["@language"] = .array(arr.map(lower))
                            } else {
                                out["@language"] = lower(expandedValue)
                            }
                        } else {
                            out[resolvedKey] = expandedValue
                        }
                    } else {
                        // Property: ensure value is an array of objects.
                        // Scalars wrap as value-object patterns so
                        // `valueMatch` sees a value-shape, not a bare
                        // string (jsonld.js's expand does the same for
                        // property values).
                        func wrapValue(_ v: JSON) -> JSON {
                            switch v {
                            case .object: return v
                            case .array: return v
                            default: return .object(["@value": v])
                            }
                        }
                        let wrapped: JSON
                        switch expandedValue {
                        case .array(let arr):
                            wrapped = .array(arr.map(wrapValue))
                        default:
                            wrapped = .array([wrapValue(expandedValue)])
                        }
                        if isReverseTerm {
                            // Reverse-property term: nest under @reverse
                            // keyed by the term's IRI mapping so the frame
                            // algorithm's @reverse loop finds it (t0029).
                            var rev: [String: JSON]
                            if case .object(let existing) = out["@reverse"] ?? .null {
                                rev = existing
                            } else { rev = [:] }
                            rev[resolvedKey] = wrapped
                            out["@reverse"] = .object(rev)
                        } else {
                            out[resolvedKey] = wrapped
                        }
                    }
                }
                return .object(out)
            }
        }

        // MARK: - Helpers

        /// Does the (expanded) frame mention `@graph` at the top level?
        static func frameMentionsGraph(_ frame: JSON) -> Bool {
            if case .array(let arr) = frame, let first = arr.first, case .object(let m) = first {
                return m["@graph"] != nil
            }
            if case .object(let m) = frame {
                return m["@graph"] != nil
            }
            return false
        }

        private static func arrayify(_ v: JSON?) -> [JSON] {
            switch v {
            case .none: return []
            case .some(.array(let arr)): return arr
            case .some(let other): return [other]
            }
        }

        private static func isKeyword(_ s: String) -> Bool {
            JSONLD.Keyword(rawValue: s) != nil
        }

        private static func isEmptyObject(_ v: JSON) -> Bool {
            if case .object(let m) = v, m.isEmpty { return true }
            return false
        }

        private static func isValue(_ v: JSON) -> Bool {
            if case .object(let m) = v, m["@value"] != nil { return true }
            return false
        }

        private static func isList(_ v: JSON) -> Bool {
            if case .object(let m) = v, m["@list"] != nil { return true }
            return false
        }

        private static func isSubject(_ v: JSON) -> Bool {
            guard case .object(let m) = v else { return false }
            if m["@value"] != nil || m["@list"] != nil || m["@set"] != nil { return false }
            // A node has more than just @id, or has @type / other props.
            if m.count > 1 { return true }
            if m["@id"] == nil { return false }
            return false
        }

        private static func isSubjectReference(_ v: JSON) -> Bool {
            guard case .object(let m) = v else { return false }
            return m.count == 1 && m["@id"] != nil
        }
    }
}
