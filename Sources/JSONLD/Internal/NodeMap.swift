import Foundation

extension JSONLD {
    /// Node Map Generation — [JSON-LD 1.1 API §9.2](https://www.w3.org/TR/json-ld11-api/#node-map-generation).
    ///
    /// Walks an expanded JSON-LD document and produces a node map:
    /// every node object is hoisted to the top level keyed by its
    /// `@id` (or a generated blank-node id), and embedded references
    /// are replaced with `{"@id": "..."}` pointers. Named graphs are
    /// kept separately keyed by the graph's @id.
    ///
    /// **Status — Phase 3 in progress.** Supports default + named
    /// graph separation, node hoisting through @list / nested values,
    /// @type IRI registration as nodes when appropriate, and a
    /// monotonically-incrementing blank-node identifier issuer.
    struct NodeMapGenerator {
        // graph-name -> subject-id -> node
        // "@default" is the default graph.
        var graphs: [String: [String: [String: JSON]]] = ["@default": [:]]
        private var blankNodeCounter = 0
        private var blankNodeMap: [String: String] = [:]

        var nodes: [String: [String: JSON]] {
            return graphs["@default"] ?? [:]
        }

        mutating func freshBlankNodeID(_ existing: String? = nil) -> String {
            if let existing, existing.hasPrefix("_:"),
               let mapped = blankNodeMap[existing]
            {
                return mapped
            }
            let id = "_:b\(blankNodeCounter)"
            blankNodeCounter += 1
            if let existing { blankNodeMap[existing] = id }
            return id
        }

        mutating func process(_ element: JSON) throws(JSONLD.Error) {
            try process(element, graph: "@default", activeSubject: nil, activeProperty: nil, list: nil)
        }

        // The list parameter, when non-nil, points to a mutable list
        // (in-out) we should append to — that lets us hoist @list
        // contents through the recursion.
        private mutating func process(
            _ element: JSON,
            graph: String,
            activeSubject: String?,
            activeProperty: String?,
            list: ListAccumulator?
        ) throws(JSONLD.Error) {
            switch element {
            case .array(let arr):
                for item in arr {
                    try process(item, graph: graph, activeSubject: activeSubject, activeProperty: activeProperty, list: list)
                }
            case .object(let map):
                try processObject(map, graph: graph, activeSubject: activeSubject, activeProperty: activeProperty, list: list)
            default:
                break
            }
        }

        // Mutable reference to a list accumulator (used to inject items
        // into a @list as the recursion descends).
        final class ListAccumulator: @unchecked Sendable {
            var items: [JSON] = []
        }

        private mutating func processObject(
            _ map: [String: JSON],
            graph: String,
            activeSubject: String?,
            activeProperty: String?,
            list: ListAccumulator?
        ) throws(JSONLD.Error) {
            // Value object — emit as-is into the active property of the
            // active subject (or the active list).
            if map["@value"] != nil {
                let valueRef = JSON.object(map)
                if let list { list.items.append(valueRef); return }
                guard let parent = activeSubject, let prop = activeProperty else { return }
                appendValueOnNode(valueRef, parent: parent, key: prop, graph: graph)
                return
            }

            // List object — recurse with a fresh accumulator so the
            // INNER items get hoisted as nodes while the @list keeps
            // their references inline.
            if let listValue = map["@list"] {
                let listAcc = ListAccumulator()
                try process(listValue, graph: graph, activeSubject: activeSubject, activeProperty: activeProperty, list: listAcc)
                let listObj = JSON.object(["@list": .array(listAcc.items)])
                if let outerList = list {
                    outerList.items.append(listObj)
                } else if let parent = activeSubject, let prop = activeProperty {
                    appendValueOnNode(listObj, parent: parent, key: prop, graph: graph)
                }
                return
            }

            // Node object. Pull out an @id (generating a blank-node id
            // when missing, normalizing existing _:... labels).
            let nodeId: String
            if case .string(let s) = map["@id"] ?? .null {
                if s.hasPrefix("_:") {
                    nodeId = freshBlankNodeID(s)
                } else {
                    nodeId = s
                }
            } else {
                nodeId = freshBlankNodeID()
            }

            // Initialize the node in this graph.
            if graphs[graph] == nil { graphs[graph] = [:] }
            if graphs[graph]?[nodeId] == nil {
                graphs[graph]?[nodeId] = ["@id": .string(nodeId)]
            }

            // Reference into the parent / list.
            let nodeRef = JSON.object(["@id": .string(nodeId)])
            if let list {
                list.items.append(nodeRef)
            } else if let parent = activeSubject, let prop = activeProperty {
                appendValueOnNode(nodeRef, parent: parent, key: prop, graph: graph)
            }

            // Process `@included` first when present. Included items
            // appear as top-level nodes; if they share an `@id` with a
            // node referenced via a property edge from this object,
            // the included node's values should accumulate FIRST so the
            // round-trip matches jsonld.js's ordering (tin06).
            if let includedValue = map["@included"] {
                try process(includedValue, graph: graph, activeSubject: nil, activeProperty: nil, list: nil)
            }

            // Walk this object's keys.
            for (key, value) in map {
                if key == "@id" { continue }
                if key == "@included" { continue }
                if key == "@type" {
                    // Hoist type IRIs into the node, normalizing blank-
                    // node labels in the values.
                    let typeJSON = remapBlankNodes(in: value)
                    appendValueOnNode(typeJSON, parent: nodeId, key: "@type", graph: graph)
                    continue
                }
                if key == "@index" || key == "@reverse" {
                    // @reverse: walk its sub-properties as REVERSE
                    // edges — the inner subject is the node, the inner
                    // property's values become FORWARD edges from the
                    // inner values to this node.
                    if key == "@reverse", case .object(let revMap) = value {
                        for (rk, rv) in revMap {
                            let items: [JSON]
                            if case .array(let arr) = rv { items = arr }
                            else { items = [rv] }
                            for item in items {
                                guard case .object(let innerMap) = item else { continue }
                                // Resolve / assign the inner node's id first.
                                let innerId: String
                                if case .string(let s) = innerMap["@id"] ?? .null {
                                    innerId = s.hasPrefix("_:") ? freshBlankNodeID(s) : s
                                } else {
                                    innerId = freshBlankNodeID()
                                }
                                // Inject the resolved id back into the
                                // map and recurse — that ensures the
                                // inner recursion reuses our id rather
                                // than minting a SECOND blank node.
                                // We also map the FRESH id back to
                                // itself so the recursive call's
                                // `freshBlankNodeID(_:b0)` call returns
                                // the same id.
                                var inner = innerMap
                                inner["@id"] = .string(innerId)
                                if innerId.hasPrefix("_:") {
                                    blankNodeMap[innerId] = innerId
                                }
                                try process(.object(inner), graph: graph, activeSubject: nil, activeProperty: nil, list: nil)
                                // Add the reverse edge: inner →[rk] → this node.
                                appendValueOnNode(.object(["@id": .string(nodeId)]), parent: innerId, key: rk, graph: graph)
                            }
                        }
                        continue
                    }
                    if key == "@index" {
                        // §9.2.6 step 6.3: if the node already has an
                        // `@index` and it doesn't equal the new value,
                        // throw `conflicting indexes`. Two `{@id: x,
                        // @index: a}` + `{@id: x, @index: b}` siblings
                        // are inconsistent (Flatten te001).
                        if let existing = graphs[graph]?[nodeId]?["@index"],
                           existing != value
                        {
                            throw .other(code: "conflicting indexes",
                                         message: "node \(nodeId) has conflicting @index values")
                        }
                        graphs[graph]?[nodeId]?["@index"] = value
                    }
                    continue
                }
                if key == "@graph" {
                    // Named graph: process the inner @graph contents
                    // in a separate graph named by this node's id.
                    try process(value, graph: nodeId, activeSubject: nil, activeProperty: nil, list: nil)
                    continue
                }
                // @included handled in the pre-pass above.
                if key.hasPrefix("@"), Keyword(rawValue: key) != nil {
                    // Other keywords pass through verbatim.
                    graphs[graph]?[nodeId]?[key] = value
                    continue
                }
                // Property — recurse into each value, attaching them
                // to this node under this key. An empty array survives
                // the flatten output (the spec preserves an empty
                // `@set` value rather than dropping the key —
                // `t0004`, `t0015`).
                if case .array(let items) = value {
                    if items.isEmpty {
                        if graphs[graph] == nil { graphs[graph] = [:] }
                        var node = graphs[graph]?[nodeId] ?? ["@id": .string(nodeId)]
                        if node[key] == nil { node[key] = .array([]) }
                        graphs[graph]?[nodeId] = node
                    }
                    for item in items {
                        try process(item, graph: graph, activeSubject: nodeId, activeProperty: key, list: nil)
                    }
                } else {
                    try process(value, graph: graph, activeSubject: nodeId, activeProperty: key, list: nil)
                }
            }
        }

        private mutating func appendValueOnNode(_ value: JSON, parent: String, key: String, graph: String) {
            if graphs[graph] == nil { graphs[graph] = [:] }
            var node = graphs[graph]?[parent] ?? ["@id": .string(parent)]
            // For @type, accumulate as an array of strings. Dedupe —
            // when the same subject is referenced from multiple places
            // (e.g. t0057's subject "I" appears in two `@list` siblings),
            // the same `@type` IRI must not be appended twice.
            if key == "@type" {
                var arr: [JSON] = []
                if case .array(let existing) = node["@type"] ?? .null {
                    arr = existing
                }
                if case .array(let new) = value {
                    for v in new where !arr.contains(v) {
                        arr.append(v)
                    }
                } else if !arr.contains(value) {
                    arr.append(value)
                }
                node["@type"] = .array(arr)
                graphs[graph]?[parent] = node
                return
            }
            // Other keys: accumulate as an array. Per
            // [§9.2.6 step 6.5](https://www.w3.org/TR/json-ld11-api/#node-map-generation),
            // exact duplicates are skipped for subject references
            // (`{@id: …}`) and value objects (`{@value: 2}`). `@list`
            // objects are NEVER deduped — the spec treats two equal
            // `{@list: …}` siblings as semantically distinct entries
            // (`t0042`).
            let isListObject: Bool = {
                if case .object(let m) = value, m["@list"] != nil { return true }
                return false
            }()
            if case .array(let existing) = node[key] ?? .null {
                if !isListObject, existing.contains(value) {
                    // skip duplicate entry
                } else {
                    node[key] = .array(existing + [value])
                }
            } else {
                node[key] = .array([value])
            }
            graphs[graph]?[parent] = node
        }

        // Normalize blank-node labels nested inside a value (e.g. @type
        // arrays may have blank-node IRIs that came in from the input).
        private mutating func remapBlankNodes(in value: JSON) -> JSON {
            switch value {
            case .string(let s) where s.hasPrefix("_:"):
                return .string(freshBlankNodeID(s))
            case .array(let arr):
                return .array(arr.map { remapBlankNodes(in: $0) })
            case .object(let m):
                var out: [String: JSON] = [:]
                for (k, v) in m { out[k] = remapBlankNodes(in: v) }
                return .object(out)
            default:
                return value
            }
        }
    }
}
