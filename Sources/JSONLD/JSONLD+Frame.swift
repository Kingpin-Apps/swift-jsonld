import Foundation

extension JSONLD {
    /// Frame a JSON-LD document with a JSON-LD frame.
    ///
    /// See [JSON-LD 1.1 Framing](https://www.w3.org/TR/json-ld11-framing/).
    /// Framing reshapes JSON-LD into the structure described by the
    /// frame — selecting nodes by `@type`, by predicate, or by example
    /// shape, and embedding matched subjects as nested objects.
    ///
    /// Frame-level defaults (`@embed`, `@explicit`, `@requireAll`,
    /// `@omitDefault`, `@omitGraph`) can be set via the framing fields
    /// on ``JSONLD/Options`` or overridden inline in the frame.
    ///
    /// - Parameters:
    ///   - input: The JSON-LD input document.
    ///   - frame: The frame document describing the desired shape.
    ///   - options: Algorithm options. Framing-specific defaults live
    ///     on ``JSONLD/Options``.
    /// - Returns: A framed document whose root is an object carrying
    ///   the frame's `@context`.
    public static func frame(
        _ input: JSON,
        frame: JSON,
        options: Options = Options()
    ) async throws(JSONLD.Error) -> JSON {
        var opts = options

        // Spec defaults that vary by processing mode.
        if opts.omitGraph == nil {
            opts.omitGraph = (opts.processingMode == .jsonLd11)
        }

        // Stash the frame's un-expanded @context for the trailing compact step.
        var frameContext: JSON = .object([:])
        if case .object(let m) = frame, let ctx = m["@context"] {
            frameContext = ctx
        }

        // Expand input (regular JSON-LD expansion).
        let expandedInput = try await expand(input, options: opts)

        // Expand frame using the frame-specific expander. The public
        // expand turns frame keyword values into value objects
        // (`@explicit: true` → `[{"@value": true}]`) and drops things it
        // can't classify — neither suits a frame. `Framing.expandFrame`
        // resolves term keys, preserves frame keywords verbatim, and
        // wraps property values in arrays.
        let baseCtx = ActiveContext(
            processingMode: opts.processingMode,
            baseIRI: opts.base
        )
        let expandedFrame = try await Framing.expandFrame(frame, activeContext: baseCtx, options: opts)

        // Build the node map.
        var generator = NodeMapGenerator()
        try generator.process(expandedInput)

        // Choose target graph(s).
        let frameUsesGraph = Framing.frameMentionsGraph(expandedFrame)
        let useMerged = !opts.frameDefault && !frameUsesGraph
        var graphMap = generator.graphs
        if useMerged {
            graphMap["@merged"] = Framing.mergeNodeMapGraphs(graphMap)
        }
        let startingGraph = useMerged ? "@merged" : "@default"

        // Frame the subjects.
        let framed = try Framing.frameMergedOrDefault(
            graphMap: graphMap,
            startingGraph: startingGraph,
            frame: expandedFrame,
            options: opts
        )

        // Compact via the internal path — public `compact` would expand
        // first, which corrupts an already-framed array. jsonld.js passes
        // `skipExpansion: true` for the same reason.
        let compactCtx = try await processContext(
            activeContext: baseCtx,
            localContext: frameContext,
            baseURL: opts.base,
            options: opts
        )
        let inverse = InverseContext(compactCtx)
        let compactedInner: JSON
        do {
            compactedInner = try await compact(
                activeContext: compactCtx,
                activeProperty: nil,
                element: framed,
                compactArrays: opts.compactArrays,
                ordered: opts.ordered,
                inverse: inverse,
                options: opts
            )
        } catch {
            compactedInner = framed
        }
        // Wrap with the frame's @context, mirroring public compact's
        // tail logic (but without re-expanding).
        let contextIsEmpty: Bool = {
            switch frameContext {
            case .object(let m): return m.isEmpty
            case .array(let a): return a.isEmpty
            case .null: return true
            default: return false
            }
        }()
        let compacted: JSON
        switch compactedInner {
        case .object(var m):
            if !contextIsEmpty { m["@context"] = frameContext }
            compacted = .object(m)
        case .array(let items) where items.isEmpty:
            compacted = .object(contextIsEmpty ? [:] : ["@context": frameContext])
        case .array(let items) where items.count == 1:
            if opts.compactArrays, case .object(var m) = items[0] {
                if !contextIsEmpty { m["@context"] = frameContext }
                compacted = .object(m)
            } else {
                var out: [String: JSON] = [
                    try inverse.compact("@graph", activeContext: compactCtx): .array(items)
                ]
                if !contextIsEmpty { out["@context"] = frameContext }
                compacted = .object(out)
            }
        default:
            var out: [String: JSON] = [
                try inverse.compact("@graph", activeContext: compactCtx): compactedInner
            ]
            if !contextIsEmpty { out["@context"] = frameContext }
            compacted = .object(out)
        }

        // Replace @null placeholders with JSON `null`.
        var cleaned = Framing.cleanupNull(compacted)

        // omitGraph: if false (the 1.0 default), force the result to be
        // wrapped in `{"@graph": [...]}`. jsonld.js passes `graph: true`
        // into compact() to do this; we post-process instead.
        if opts.omitGraph == false {
            switch cleaned {
            case .object(var m) where m["@graph"] == nil:
                let context = m.removeValue(forKey: "@context")
                var wrapper: [String: JSON] = [:]
                if let ctx = context { wrapper["@context"] = ctx }
                if m.isEmpty {
                    wrapper["@graph"] = .array([])
                } else {
                    wrapper["@graph"] = .array([.object(m)])
                }
                cleaned = .object(wrapper)
            case .array(let arr):
                var wrapper: [String: JSON] = [:]
                wrapper["@graph"] = .array(arr)
                cleaned = .object(wrapper)
            default: break
            }
        }

        // Ensure the result carries the frame's @context (compact drops
        // it for empty inputs; injecting here keeps round-trips intact).
        if case .object(let frameCtxMap) = frameContext, !frameCtxMap.isEmpty {
            if case .object(var m) = cleaned, m["@context"] == nil {
                m["@context"] = frameContext
                cleaned = .object(m)
            }
        } else if case .array = frameContext {
            if case .object(var m) = cleaned, m["@context"] == nil {
                m["@context"] = frameContext
                cleaned = .object(m)
            }
        }

        // Collapse nested single-element `@graph` arrays for `compactArrays`
        // mode. Compact emits `[obj]` for a single inner node; the spec
        // permits @graph to be a bare object when there's one entry, and
        // the framing tests (t0047, t0050, tg010) expect that shape.
        // Skip the top-level @graph if `omitGraph: false` was applied
        // above — the wrapper there is structural.
        if opts.compactArrays {
            cleaned = collapseSingleGraph(cleaned, atTopLevel: true, omitGraphFalse: opts.omitGraph == false)
        }

        return cleaned
    }

    private static func collapseSingleGraph(_ value: JSON, atTopLevel: Bool, omitGraphFalse: Bool) -> JSON {
        switch value {
        case .object(let m):
            var out: [String: JSON] = [:]
            for (k, v) in m {
                if k == "@graph", case .array(let arr) = v, arr.count == 1 {
                    if atTopLevel && omitGraphFalse {
                        // Structural wrapper from omitGraph: false — keep array.
                        out[k] = .array([collapseSingleGraph(arr[0], atTopLevel: false, omitGraphFalse: false)])
                    } else {
                        out[k] = collapseSingleGraph(arr[0], atTopLevel: false, omitGraphFalse: false)
                    }
                } else {
                    out[k] = collapseSingleGraph(v, atTopLevel: false, omitGraphFalse: false)
                }
            }
            return .object(out)
        case .array(let arr):
            return .array(arr.map { collapseSingleGraph($0, atTopLevel: false, omitGraphFalse: false) })
        default:
            return value
        }
    }
}
