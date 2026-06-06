import Foundation

extension JSONLD {
    /// Serialize RDF as JSON-LD — [JSON-LD 1.1 API §11](https://www.w3.org/TR/json-ld11-api/#serialize-rdf-as-json-ld-algorithm).
    ///
    /// Converts an RDF dataset back to (expanded) JSON-LD. Each
    /// subject becomes a node object; literals become value objects;
    /// `rdf:first`/`rdf:rest` chains rebuild into `@list` objects;
    /// named graphs become `@graph` containers.
    ///
    /// Honors the `useNativeTypes` and `useRdfType` options.
    static func fromRDF(dataset: Dataset, options: Options) throws(JSONLD.Error) -> JSON {
        var builder = FromRDFBuilder(
            useNativeTypes: options.useNativeTypes,
            useRdfType: options.useRdfType
        )
        builder.ingest(dataset)
        if let err = builder.deferredError { throw err }
        builder.convertLists()
        return builder.finalize()
    }
}

/// Implements [§11 Serialize RDF as JSON-LD](https://www.w3.org/TR/json-ld11-api/#serialize-rdf-as-json-ld-algorithm).
///
/// Walks the dataset once, builds a per-graph node map, runs the
/// list-conversion pass, then emits the final array.
private struct FromRDFBuilder {
    let useNativeTypes: Bool
    let useRdfType: Bool

    /// First non-recoverable spec error detected during ingest (e.g.
    /// `invalid JSON literal` on a `rdf:JSON`-typed literal whose
    /// lexical form doesn't parse as JSON). Surfaced after ingest
    /// instead of mid-walk to keep `ingest`/`termToValue` non-throwing.
    var deferredError: JSONLD.Error? = nil

    private static let rdfFirst = "http://www.w3.org/1999/02/22-rdf-syntax-ns#first"
    private static let rdfRest = "http://www.w3.org/1999/02/22-rdf-syntax-ns#rest"
    private static let rdfNil = "http://www.w3.org/1999/02/22-rdf-syntax-ns#nil"
    private static let rdfType = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    private static let rdfLangString = JSONLD.Literal.rdfLangString
    private static let rdfJSON = JSONLD.Literal.rdfJSON
    private static let xsdBoolean = JSONLD.Literal.xsdBoolean
    private static let xsdInteger = JSONLD.Literal.xsdInteger
    private static let xsdDouble = JSONLD.Literal.xsdDouble
    private static let xsdString = JSONLD.Literal.xsdString

    /// One usage of a list node: where it was referenced as the object
    /// of a triple. Captures the chain context needed for the list
    /// conversion pass.
    private struct Usage {
        var graphName: String
        var subjectID: String
        var property: String
    }

    /// One node within a graph: its predicate→[value-object] map plus
    /// list-detection metadata.
    private struct NodeShell {
        var properties: [String: [JSONLD.JSON]] = [:]
        // Set when this node carries an rdf:first/rdf:rest pair (and
        // optionally rdf:type rdf:List). Indexed by who refers to it.
        var usages: [Usage] = []
        // Count of times this node appears as the object of any
        // non-list-cell triple. If >1, the node cannot collapse to a
        // single @list.
        var nonCellUsages: Int = 0
    }

    /// Default-graph + named-graph node maps. Default graph key is `""`.
    private var graphs: [String: [String: NodeShell]] = ["": [:]]
    /// Count of how many quads have each blank node as their object,
    /// summed across all graphs. Used to abort list conversion when
    /// a chain cell is also referenced from outside the current graph.
    private var globalBlankUsages: [String: Int] = [:]
    /// Set of graph names actually observed (so we can emit even
    /// empty default-graph entries for graph names that appear only
    /// as subjects somewhere).
    private var graphNames: Set<String> = [""]

    init(useNativeTypes: Bool, useRdfType: Bool) {
        self.useNativeTypes = useNativeTypes
        self.useRdfType = useRdfType
    }

    /// Walk every quad, populate the node map.
    mutating func ingest(_ dataset: JSONLD.Dataset) {
        // Visit the default graph first so its node ordering is stable.
        for q in dataset.defaultGraph {
            ingest(q, into: "")
        }
        for name in dataset.namedGraphs.keys.sorted() {
            graphNames.insert(name)
            graphs[name] = [:]
            for q in dataset.namedGraphs[name] ?? [] {
                ingest(q, into: name)
            }
            // Ensure the graph name is also a node in the default graph
            // (its containing record).
            let key = name
            if graphs[""]?[key] == nil {
                var shell = NodeShell()
                shell.properties["@id"] = [.string(key)]
                graphs[""]?[key] = shell
            }
        }
    }

    private mutating func ingest(_ quad: JSONLD.Quad, into graphName: String) {
        let subjKey = nodeKey(quad.subject)
        ensureNode(subjKey, in: graphName)

        // Always emit a `usages` entry for the OBJECT side of every
        // quad whose object is a node (IRI or blank). We use that to
        // detect list cells.
        let objKey: String?
        switch quad.object {
        case .iri(let s): objKey = s
        case .blankNode(let s): objKey = s
        case .literal: objKey = nil
        }
        if let objKey {
            ensureNode(objKey, in: graphName)
        }

        guard case .iri(let predIRI) = quad.predicate else {
            // Non-IRI predicates are generalized RDF; ignore.
            return
        }

        // rdf:type → @type (unless useRdfType).
        if predIRI == Self.rdfType, !useRdfType, case .iri(let typeIRI) = quad.object {
            var shell = graphs[graphName]![subjKey]!
            var arr: [JSONLD.JSON]
            if case .array(let existing) = shell.properties["@type"]?.first ?? .null {
                arr = existing
            } else {
                arr = (shell.properties["@type"] ?? [])
            }
            if !arr.contains(.string(typeIRI)) {
                arr.append(.string(typeIRI))
            }
            shell.properties["@type"] = arr
            graphs[graphName]![subjKey] = shell
            return
        }

        // Append the value to the predicate's bucket; de-dup against
        // exact matches per §11.3 step 3.
        let valueJSON = self.termToValue(quad.object)
        var shell = graphs[graphName]![subjKey]!
        var bucket = shell.properties[predIRI] ?? []
        let isDuplicate = bucket.contains(valueJSON)
        if !isDuplicate {
            bucket.append(valueJSON)
        }
        shell.properties[predIRI] = bucket
        graphs[graphName]![subjKey] = shell

        // Track usage of the object node for list detection. Skip
        // duplicate triples — they shouldn't count as a second usage.
        if let objKey, !isDuplicate {
            var objShell = graphs[graphName]![objKey]!
            objShell.usages.append(Usage(
                graphName: graphName,
                subjectID: subjKey,
                property: predIRI
            ))
            if predIRI != Self.rdfFirst, predIRI != Self.rdfRest {
                objShell.nonCellUsages += 1
            }
            graphs[graphName]![objKey] = objShell
        }
        // For blank-node objects, remember the cross-graph usage on
        // a global counter so a chain in one graph can detect that
        // its tail is also referenced from another graph and bail.
        // Skip duplicate triples so the global count stays consistent
        // with per-graph usage counts.
        if case .blankNode(let id) = quad.object, !isDuplicate {
            globalBlankUsages[id, default: 0] += 1
        }
    }

    private mutating func ensureNode(_ id: String, in graphName: String) {
        if graphs[graphName] == nil { graphs[graphName] = [:] }
        if graphs[graphName]![id] == nil {
            var shell = NodeShell()
            shell.properties["@id"] = [.string(id)]
            graphs[graphName]![id] = shell
        }
    }

    /// Convert a term to its `@value`/node-reference JSON form.
    private mutating func termToValue(_ term: JSONLD.Term) -> JSONLD.JSON {
        switch term {
        case .iri(let iri):
            return .object(["@id": .string(iri)])
        case .blankNode(let id):
            return .object(["@id": .string(id)])
        case .literal(let lit):
            return literalToValue(lit)
        }
    }

    private mutating func literalToValue(_ lit: JSONLD.Literal) -> JSONLD.JSON {
        var obj: [String: JSONLD.JSON] = [:]

        if lit.datatype == Self.rdfJSON {
            // Parse the lexical form as JSON; emit as `@value: <decoded>`
            // with `@type: @json`. Per §11 if the lexical form isn't
            // valid JSON, the spec error is `invalid JSON literal`.
            obj["@type"] = .string("@json")
            if let data = lit.value.data(using: .utf8),
               let any = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]
               ),
               let json = try? JSONFixtureBridge.toJSON(any)
            {
                obj["@value"] = json
            } else if deferredError == nil {
                deferredError = .other(code: "invalid JSON literal",
                                       message: "rdf:JSON literal lexical form is not valid JSON: \(lit.value)")
                obj["@value"] = .string(lit.value)
            } else {
                obj["@value"] = .string(lit.value)
            }
            return .object(obj)
        }

        if useNativeTypes {
            switch lit.datatype {
            case Self.xsdBoolean:
                // XSD lexical mappings for boolean: true/1 → true,
                // false/0 → false. Other lexical forms aren't natively
                // representable; preserve them as typed string values.
                if lit.value == "true" || lit.value == "1" {
                    obj["@value"] = .bool(true); return .object(obj)
                }
                if lit.value == "false" || lit.value == "0" {
                    obj["@value"] = .bool(false); return .object(obj)
                }
            case Self.xsdInteger:
                if let i = Int64(lit.value) { obj["@value"] = .int(i); return .object(obj) }
            case Self.xsdDouble:
                // Only convert if the parsed double round-trips —
                // INF/-INF/NaN aren't representable in JSON, neither
                // are out-of-range exponents like `0.1e9999999`.
                if let d = Double(lit.value), d.isFinite {
                    obj["@value"] = .double(d); return .object(obj)
                }
            default: break
            }
        }

        obj["@value"] = .string(lit.value)
        if let lang = lit.language {
            obj["@language"] = .string(lang)
        } else if lit.datatype != Self.xsdString {
            obj["@type"] = .string(lit.datatype)
        }
        if let dir = lit.direction { obj["@direction"] = .string(dir) }
        return .object(obj)
    }

    /// [§11.3 step 4](https://www.w3.org/TR/json-ld11-api/#serialize-rdf-as-json-ld-algorithm)
    /// — collapse rdf:first/rdf:rest chains into `@list` objects.
    mutating func convertLists() {
        for graphName in graphs.keys {
            convertLists(in: graphName)
        }
    }

    private mutating func convertLists(in graphName: String) {
        // Loop until no chains were converted in a pass — needed so
        // nested lists collapse from the inside out.
        var keepGoing = true
        while keepGoing {
            keepGoing = convertOneListPass(in: graphName)
        }
        // rdf:nil-as-object → `@list:[]`. Done last so tail detection
        // during the conversion loop still sees `rdf:nil` references
        // as the terminator instead of an empty-list value.
        rewriteNilReferences(in: graphName)
    }

    @discardableResult
    private mutating func convertOneListPass(in graphName: String) -> Bool {
        guard let nodes = graphs[graphName] else { return false }

        // Find "tail cells": well-formed blank-node cells whose
        // rdf:rest points to rdf:nil. Sort for determinism.
        var tails: [String] = []
        for (id, shell) in nodes {
            guard id.hasPrefix("_:") else { continue }
            guard isWellFormedListCell(shell) else { continue }
            if let rests = shell.properties[Self.rdfRest], rests.count == 1,
               case .object(let m) = rests[0],
               case .string(let next) = m["@id"] ?? .null,
               next == Self.rdfNil
            {
                tails.append(id)
            }
        }
        tails.sort()

        var toDelete: Set<String> = []
        var convertedAny = false

        for tail in tails {
            if toDelete.contains(tail) { continue }

            // Walk backward through rdf:rest references — at each
            // step the previous cell must also be a well-formed list
            // cell whose only usage matches the chain (rdf:rest from
            // exactly one predecessor) so the chain stays linear.
            var chain: [String] = [tail]
            var headID = tail
            while true {
                guard let shell = graphs[graphName]?[headID] else { break }
                // For a non-head cell, its usages must be exactly one
                // rdf:rest usage from the previous cell (already
                // included). For the current head, it can have any
                // number of usages, but to be eligible for further
                // backward walking it must have a single rdf:rest
                // usage from a well-formed list cell.
                let restUsages = shell.usages.filter { $0.property == Self.rdfRest }
                let nonCellUsages = shell.usages.count - restUsages.count
                if nonCellUsages > 0 { break }
                if restUsages.count != 1 { break }
                let prevID = restUsages[0].subjectID
                guard let prevShell = graphs[graphName]?[prevID] else { break }
                guard prevID.hasPrefix("_:") else { break }
                guard isWellFormedListCell(prevShell) else { break }
                // Avoid cycles.
                if chain.contains(prevID) { break }
                // Don't pull a cross-graph-referenced cell into the
                // chain — its identity must remain visible outside.
                if (globalBlankUsages[prevID] ?? 0) > prevShell.usages.count { break }
                chain.append(prevID)
                headID = prevID
            }

            // Chain was built tail→head; reverse to head→tail.
            chain.reverse()

            // Cells referenced from outside this graph can't collapse —
            // their identity is observable elsewhere. Compare each
            // cell's in-graph usages against the global object-position
            // counter; any excess means a cross-graph reference.
            var crossGraph = false
            for cellID in chain {
                guard let cell = graphs[graphName]?[cellID] else { crossGraph = true; break }
                if (globalBlankUsages[cellID] ?? 0) > cell.usages.count {
                    crossGraph = true; break
                }
            }
            if crossGraph { continue }

            // If any cell's rdf:first still references an un-processed
            // list-cell head, defer this chain — the inner chain must
            // collapse first so we pick up its `@list` form.
            var defer_ = false
            for cellID in chain {
                guard let cell = graphs[graphName]?[cellID] else { defer_ = true; break }
                let firsts = cell.properties[Self.rdfFirst] ?? []
                guard firsts.count == 1 else { defer_ = true; break }
                if case .object(let m) = firsts[0],
                   case .string(let refID) = m["@id"] ?? .null,
                   let refShell = graphs[graphName]?[refID],
                   isWellFormedListCell(refShell)
                {
                    defer_ = true; break
                }
            }
            if defer_ { continue }

            // Collect list values in head→tail order.
            var listValues: [JSONLD.JSON] = []
            for cellID in chain {
                guard let cell = graphs[graphName]?[cellID] else { listValues = []; break }
                let firsts = cell.properties[Self.rdfFirst] ?? []
                if firsts.count == 1 { listValues.append(firsts[0]) }
            }
            if listValues.isEmpty, !chain.isEmpty {
                // All cells must contribute one rdf:first.
                continue
            }

            // After the backward walk, the head cell has exactly one
            // usage — the inbound reference we'll rewrite to `@list`.
            // (Multiple usages or zero usages disqualify the chain.)
            guard let headShell = graphs[graphName]?[headID] else { continue }
            guard headShell.usages.count == 1 else { continue }
            let headUsage = headShell.usages[0]

            // Rewrite the head's single referencing bucket entry.
            guard var refShell = graphs[headUsage.graphName]?[headUsage.subjectID] else { continue }
            var bucket = refShell.properties[headUsage.property] ?? []
            for i in 0..<bucket.count {
                if case .object(let m) = bucket[i],
                   case .string(let id) = m["@id"] ?? .null,
                   id == headID
                {
                    bucket[i] = .object(["@list": .array(listValues)])
                    break
                }
            }
            refShell.properties[headUsage.property] = bucket
            graphs[headUsage.graphName]![headUsage.subjectID] = refShell

            for cellID in chain { toDelete.insert(cellID) }
            convertedAny = true
        }

        for id in toDelete { graphs[graphName]?.removeValue(forKey: id) }
        return convertedAny
    }

    /// A node is a well-formed list cell iff it has exactly one
    /// rdf:first, exactly one rdf:rest, optionally `rdf:type rdf:List`
    /// (with that single value), and no other predicates.
    private func isWellFormedListCell(_ shell: NodeShell) -> Bool {
        let firsts = shell.properties[Self.rdfFirst] ?? []
        let rests = shell.properties[Self.rdfRest] ?? []
        if firsts.count != 1 || rests.count != 1 { return false }
        for k in shell.properties.keys {
            switch k {
            case "@id", Self.rdfFirst, Self.rdfRest: continue
            case "@type":
                let types = shell.properties["@type"] ?? []
                if types.count == 1,
                   case .string(let t) = types[0],
                   t == "http://www.w3.org/1999/02/22-rdf-syntax-ns#List"
                { continue }
                return false
            default:
                return false
            }
        }
        return true
    }

    /// Walk an rdf:rest chain starting at `cellID`.
    private func walkChain(start: String, in graphName: String) -> [String]? {
        var chain: [String] = []
        var current = start
        var seen: Set<String> = []
        while !seen.contains(current) {
            seen.insert(current)
            chain.append(current)
            guard let shell = graphs[graphName]?[current] else { return nil }
            let rests = shell.properties[Self.rdfRest] ?? []
            guard rests.count == 1 else { return nil }
            if case .object(let m) = rests[0], case .string(let nextID) = m["@id"] ?? .null {
                if nextID == Self.rdfNil { return chain }
                current = nextID
            } else {
                return nil
            }
        }
        return nil
    }

    private func isNilTerminated(cell cellID: String, in graphName: String) -> Bool {
        guard let shell = graphs[graphName]?[cellID] else { return false }
        let rests = shell.properties[Self.rdfRest] ?? []
        guard rests.count == 1 else { return false }
        if case .object(let m) = rests[0], case .string(let next) = m["@id"] ?? .null {
            return next == Self.rdfNil
        }
        return false
    }

    /// Replace every `{@id: rdf:nil}` reference (object position) in
    /// the graph with `{@list: []}`. rdf:nil's own node is left alone
    /// in case it's also a subject elsewhere.
    private mutating func rewriteNilReferences(in graphName: String) {
        guard let nodes = graphs[graphName] else { return }
        for (nodeID, shell) in nodes {
            var changed = false
            var newProperties = shell.properties
            for (predicate, bucket) in shell.properties {
                if predicate == "@id" || predicate == "@type" { continue }
                var newBucket = bucket
                for i in 0..<newBucket.count {
                    newBucket[i] = rewriteNilInValue(newBucket[i])
                    if newBucket[i] != bucket[i] { changed = true }
                }
                newProperties[predicate] = newBucket
            }
            if changed {
                var newShell = shell
                newShell.properties = newProperties
                graphs[graphName]![nodeID] = newShell
            }
        }
    }

    /// Replace `{@id: rdf:nil}` with `{@list: []}` recursively — also
    /// walks into `@list` arrays so nested rdf:nil items get rewritten.
    private func rewriteNilInValue(_ value: JSONLD.JSON) -> JSONLD.JSON {
        guard case .object(let m) = value else { return value }
        if case .string(let id) = m["@id"] ?? .null, id == Self.rdfNil {
            return .object(["@list": .array([])])
        }
        if case .array(let items) = m["@list"] ?? .null {
            let rewritten = items.map(rewriteNilInValue)
            var out = m
            out["@list"] = .array(rewritten)
            return .object(out)
        }
        return value
    }

    /// Emit the final JSON array. Default-graph nodes come first;
    /// named-graph contents are folded into a `@graph` entry on the
    /// node whose `@id` matches the graph name.
    func finalize() -> JSONLD.JSON {
        // Build per-graph node arrays.
        var defaultArray: [JSONLD.JSON] = []
        let defaultNodes = graphs[""] ?? [:]
        let sortedDefaultIDs = defaultNodes.keys.sorted()

        for id in sortedDefaultIDs {
            // rdf:nil is normally a list terminator that gets rewritten
            // to `@list:[]` — but if it appears as the subject of any
            // real triple, keep it as a node.
            if let node = makeNodeObject(defaultNodes[id]!) {
                defaultArray.append(node)
            }
        }

        // Fold each named graph into its corresponding default-graph node.
        for graphName in graphs.keys.sorted() {
            if graphName.isEmpty { continue }
            let nodes = graphs[graphName] ?? [:]
            var graphContents: [JSONLD.JSON] = []
            for id in nodes.keys.sorted() {
                if let node = makeNodeObject(nodes[id]!) {
                    graphContents.append(node)
                }
            }
            // Locate or create the wrapper node.
            var wrapperIdx: Int? = nil
            for (i, n) in defaultArray.enumerated() {
                if case .object(let m) = n,
                   case .string(let id) = m["@id"] ?? .null,
                   id == graphName
                { wrapperIdx = i; break }
            }
            if let idx = wrapperIdx, case .object(var m) = defaultArray[idx] {
                m["@graph"] = .array(graphContents)
                defaultArray[idx] = .object(m)
            } else {
                defaultArray.append(.object([
                    "@id": .string(graphName),
                    "@graph": .array(graphContents)
                ]))
            }
        }

        return .array(defaultArray)
    }

    private func makeNodeObject(_ shell: NodeShell) -> JSONLD.JSON? {
        var node: [String: JSONLD.JSON] = [:]
        // @id first.
        if let id = shell.properties["@id"]?.first {
            node["@id"] = id
        }
        // @type.
        if let typeBucket = shell.properties["@type"], !typeBucket.isEmpty {
            node["@type"] = .array(typeBucket)
        }
        for (predicate, bucket) in shell.properties {
            if predicate == "@id" || predicate == "@type" { continue }
            if bucket.isEmpty { continue }
            node[predicate] = .array(bucket)
        }
        // Nodes that carry only `@id` (no predicates, no @type) are
        // reference-only — they appeared as the object of some triple
        // but never as a subject in this graph. Drop them; the
        // reference still survives via the value object inside the
        // referring node.
        if node.count == 1, node["@id"] != nil { return nil }
        return .object(node)
    }

    private func nodeKey(_ term: JSONLD.Term) -> String {
        switch term {
        case .iri(let s): return s
        case .blankNode(let s): return s
        case .literal: return "_:literal-subject"
        }
    }
}

/// Adapter — keeps `JSONFixture.toJSON` (defined in the test target)
/// from leaking into the library. We re-implement the same conversion
/// here so the library can build without the test target.
private enum JSONFixtureBridge {
    static func toJSON(_ any: Any) throws -> JSONLD.JSON {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d.truncatingRemainder(dividingBy: 1) == 0,
               d >= Double(Int64.min), d <= Double(Int64.max)
            {
                return .int(Int64(d))
            }
            return .double(d)
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(try arr.map(toJSON)) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONLD.JSON] = [:]
            for (k, v) in dict { out[k] = try toJSON(v) }
            return .object(out)
        }
        struct UnsupportedType: Error { let valueType: String }
        throw UnsupportedType(valueType: String(describing: type(of: any)))
    }
}
