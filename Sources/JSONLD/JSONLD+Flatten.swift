import Foundation

extension JSONLD {
    /// Flatten a JSON-LD document into a single-level node array.
    ///
    /// See [JSON-LD 1.1 API §3.1.3](https://www.w3.org/TR/json-ld11-api/#dom-jsonldprocessor-flatten).
    /// Flattening expands the input, walks it to build a node map
    /// (every node hoisted to the top level keyed by `@id`, embedded
    /// nodes replaced by `{"@id": "…"}` pointers), and — when a
    /// `context` is supplied — compacts the result.
    ///
    /// - Parameters:
    ///   - input: The JSON-LD input.
    ///   - context: Optional target context for compaction. When `nil`,
    ///     the flat expanded form is returned as an array of nodes.
    ///   - options: Algorithm options.
    public static func flatten(
        _ input: JSON,
        context: JSON? = nil,
        options: Options = Options()
    ) async throws(JSONLD.Error) -> JSON {
        let expanded = try await expand(input, options: options)

        var generator = NodeMapGenerator()
        try generator.process(expanded)

        // Emit default graph nodes, with named graphs hoisted as
        // {"@id": <gid>, "@graph": [...]} entries. Free-floating
        // "subject reference" nodes (only @id, no other properties)
        // are dropped per §4.4 "Flattening".
        // Drop @id-only free-floating subject refs from a sorted node-id
        // sequence (§4.4 — bare references to absent nodes don't survive
        // flatten).
        func nonEmptyNodes(_ ids: [String], in graph: [String: [String: JSON]]) -> [JSON] {
            ids.compactMap { id -> JSON? in
                guard let node = graph[id] else { return nil }
                if node.count == 1, node["@id"] != nil { return nil }
                return .object(node)
            }
        }

        var output: [JSON] = []
        let defaultGraph = generator.graphs["@default"] ?? [:]
        let defaultSortedIDs = defaultGraph.keys.sorted()
        for id in defaultSortedIDs {
            var node = defaultGraph[id]!
            // If there's a named graph keyed by this node's id, attach
            // its contents as @graph.
            if let named = generator.graphs[id], !named.isEmpty {
                let inner = nonEmptyNodes(named.keys.sorted(), in: generator.graphs[id] ?? [:])
                node["@graph"] = .array(inner)
            }
            // Drop @id-only free-floating subject refs.
            if node.count == 1, node["@id"] != nil { continue }
            output.append(.object(node))
        }
        // Add any named graphs whose subject ID didn't appear in the
        // default graph.
        for graphId in generator.graphs.keys.sorted() {
            if graphId == "@default" { continue }
            if defaultGraph[graphId] != nil { continue }
            guard let named = generator.graphs[graphId], !named.isEmpty else { continue }
            let inner = nonEmptyNodes(named.keys.sorted(), in: named)
            if inner.isEmpty { continue }
            output.append(.object([
                "@id": .string(graphId),
                "@graph": .array(inner),
            ]))
        }
        let flatArray = JSON.array(output)

        guard let context else { return flatArray }
        return try await compact(flatArray, context: context, options: options)
    }
}
