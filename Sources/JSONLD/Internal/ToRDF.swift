import Foundation

extension JSONLD {
    /// Deserialize JSON-LD to RDF — [JSON-LD 1.1 API §10](https://www.w3.org/TR/json-ld11-api/#deserialize-json-ld-to-rdf-algorithm).
    ///
    /// Walks an expanded JSON-LD document, producing one quad per
    /// (subject, predicate, object) triple. Subjects come from
    /// `@id` (or generated blank-node ids); predicates from property
    /// IRIs; objects from value objects, references, or nested nodes.
    ///
    /// **Status — Phase 4 in progress.** Single-graph handling
    /// (default graph) covers the common case; `@graph` containers
    /// produce named graphs but with limited per-graph blank-node
    /// scoping. Lists generate the standard `rdf:first`/`rdf:rest`/
    /// `rdf:nil` chain.
    static func toRDF(expanded: JSON) -> Dataset {
        var emitter = QuadEmitter()
        emitter.walkTopLevel(expanded)
        return emitter.dataset
    }
}

private struct QuadEmitter {
    var dataset = JSONLD.Dataset()
    private var bnCounter = 0
    /// Rename map for explicit `_:` labels from the input. Each
    /// distinct input label gets its own fresh `_:b<n>` so an input
    /// `"_:b0"` reference doesn't collide with the `_:b0` we'd hand
    /// out as the implicit id for an anonymous outer node
    /// ([§10.3 Blank Node Identifier Generation](https://www.w3.org/TR/json-ld11-api/#dfn-blank-node-identifier-generation),
    /// `t0119`).
    private var blankRenames: [String: String] = [:]

    private static let rdfFirst = "http://www.w3.org/1999/02/22-rdf-syntax-ns#first"
    private static let rdfRest = "http://www.w3.org/1999/02/22-rdf-syntax-ns#rest"
    private static let rdfNil = "http://www.w3.org/1999/02/22-rdf-syntax-ns#nil"
    private static let rdfType = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

    mutating func nextBN() -> String {
        defer { bnCounter += 1 }
        return "_:b\(bnCounter)"
    }

    /// Resolve an input `_:` label to its fresh, collision-free form.
    mutating func renameBlank(_ id: String) -> String {
        if let r = blankRenames[id] { return r }
        let fresh = nextBN()
        blankRenames[id] = fresh
        return fresh
    }

    mutating func walkTopLevel(_ element: JSONLD.JSON) {
        switch element {
        case .array(let items):
            for item in items { walkTopLevel(item) }
        case .object(let map):
            _ = emitNode(map, graphName: nil)
        default:
            break
        }
    }

    /// Emit quads for one node object. Returns the subject term so
    /// callers nesting this node as an object can reference it.
    mutating func emitNode(_ map: [String: JSONLD.JSON], graphName: JSONLD.Term?) -> JSONLD.Term {
        // Skip value / list objects — they're objects of triples, not subjects.
        if map["@value"] != nil { return objectFromValue(map) }
        if map["@list"] != nil { return objectFromList(map["@list"]!, graphName: graphName) }

        let subject: JSONLD.Term
        if case .string(let id) = map["@id"] ?? .null {
            if id.hasPrefix("_:") { subject = .blankNode(renameBlank(id)) }
            else { subject = .iri(id) }
        } else {
            subject = .blankNode(nextBN())
        }

        for (key, value) in map {
            if key == "@id" || key == "@context" || key == "@index" { continue }

            if key == "@type" {
                let types = expandToStringArray(value)
                for t in types {
                    let object: JSONLD.Term = t.hasPrefix("_:") ? .blankNode(renameBlank(t)) : .iri(t)
                    emitQuad(
                        subject: subject,
                        predicate: .iri(Self.rdfType),
                        object: object,
                        graph: graphName
                    )
                }
                continue
            }

            if key == "@graph", case .array(let inner) = value {
                let graphTerm: JSONLD.Term
                if case .iri(let iri) = subject { graphTerm = .iri(iri) }
                else if case .blankNode(let id) = subject { graphTerm = .blankNode(id) }
                else { graphTerm = subject }
                for item in inner {
                    if case .object(let inMap) = item {
                        _ = emitNode(inMap, graphName: graphTerm)
                    }
                }
                continue
            }

            // @included — emit each item as a node in the current graph
            // ([JSON-LD 1.1 API §10.1 step 5](https://www.w3.org/TR/json-ld11-api/#deserialize-json-ld-to-rdf-algorithm)).
            if key == "@included", case .array(let inner) = value {
                for item in inner {
                    if case .object(let inMap) = item {
                        _ = emitNode(inMap, graphName: graphName)
                    }
                }
                continue
            }

            // @reverse — for each predicate within, emit each child as
            // a subject with an edge pointing back to the outer subject.
            if key == "@reverse", case .object(let rmap) = value {
                for (predIRI, predValue) in rmap {
                    if predIRI.hasPrefix("@") { continue }
                    let items: [JSONLD.JSON]
                    if case .array(let arr) = predValue { items = arr } else { items = [predValue] }
                    for item in items {
                        if case .object(let inner) = item {
                            let childSubject = emitNode(inner, graphName: graphName)
                            emitQuad(
                                subject: childSubject,
                                predicate: .iri(predIRI),
                                object: subject,
                                graph: graphName
                            )
                        }
                    }
                }
                continue
            }

            if key.hasPrefix("@") { continue }

            let predicate = JSONLD.Term.iri(key)
            let items: [JSONLD.JSON]
            if case .array(let arr) = value { items = arr } else { items = [value] }

            for item in items {
                if case .object(let inner) = item {
                    // `{"@id": null}` — explicit null id from a keyword-form
                    // string that resolved to nothing (te122). The slot
                    // survives expansion to keep the property visible, but
                    // it represents no RDF identity, so no triple emits.
                    if inner.count == 1, case .some(.null) = inner["@id"] {
                        continue
                    }
                    if inner["@list"] != nil {
                        let listHead = objectFromList(inner["@list"]!, graphName: graphName)
                        emitQuad(subject: subject, predicate: predicate, object: listHead, graph: graphName)
                    } else if inner["@value"] != nil {
                        let lit = objectFromValue(inner)
                        emitQuad(subject: subject, predicate: predicate, object: lit, graph: graphName)
                    } else {
                        // Nested node — emit its quads and use its subject as object.
                        let nestedSubject = emitNode(inner, graphName: graphName)
                        emitQuad(subject: subject, predicate: predicate, object: nestedSubject, graph: graphName)
                    }
                } else if case .string(let s) = item {
                    // Bare string (shouldn't happen after expansion, but tolerate).
                    emitQuad(
                        subject: subject,
                        predicate: predicate,
                        object: .literal(JSONLD.Literal(value: s)),
                        graph: graphName
                    )
                }
            }
        }

        return subject
    }

    func objectFromValue(_ map: [String: JSONLD.JSON]) -> JSONLD.Term {
        guard let raw = map["@value"] else { return .literal(JSONLD.Literal(value: "")) }
        var datatype = JSONLD.Literal.xsdString
        var lang: String? = nil
        var direction: String? = nil
        if case .string(let t) = map["@type"] ?? .null { datatype = t }
        if case .string(let l) = map["@language"] ?? .null {
            lang = l
            if map["@type"] == nil { datatype = JSONLD.Literal.rdfLangString }
        }
        if case .string(let d) = map["@direction"] ?? .null { direction = d }

        // @type: @json — JSON-canonicalize the raw value (RFC 8785-ish)
        // and emit as rdf:JSON.
        if datatype == "@json" {
            let canonical = JCS.canonicalize(raw)
            return .literal(JSONLD.Literal(value: canonical, datatype: JSONLD.Literal.rdfJSON))
        }

        let value: String
        switch raw {
        case .string(let s): value = s
        case .int(let i):
            // Integers coerced to xsd:double get canonical double form.
            if datatype == JSONLD.Literal.xsdDouble {
                value = XSDNumber.canonicalDouble(Double(i))
            } else {
                value = String(i)
                if datatype == JSONLD.Literal.xsdString { datatype = JSONLD.Literal.xsdInteger }
            }
        case .double(let d):
            if datatype == JSONLD.Literal.xsdString { datatype = JSONLD.Literal.xsdDouble }
            // Per [§10.4](https://www.w3.org/TR/json-ld11-api/#data-round-tripping):
            // fractional doubles use canonical-double lexical form even
            // when the declared type is xsd:integer; whole-number doubles
            // declared as xsd:integer use the integer canonical mapping.
            if datatype == JSONLD.Literal.xsdInteger,
               d.truncatingRemainder(dividingBy: 1) == 0,
               abs(d) < 1e21
            {
                value = String(Int64(d))
            } else {
                value = XSDNumber.canonicalDouble(d)
            }
        case .bool(let b):
            value = b ? "true" : "false"
            if datatype == JSONLD.Literal.xsdString { datatype = JSONLD.Literal.xsdBoolean }
        default: value = ""
        }
        return .literal(JSONLD.Literal(value: value, datatype: datatype, language: lang, direction: direction))
    }

    mutating func objectFromList(_ value: JSONLD.JSON, graphName: JSONLD.Term?) -> JSONLD.Term {
        let items: [JSONLD.JSON]
        if case .array(let arr) = value { items = arr } else { items = [value] }
        if items.isEmpty { return .iri(Self.rdfNil) }

        // Generate fresh blank nodes for each cell, link them.
        let cells = (0..<items.count).map { _ in nextBN() }
        for (idx, item) in items.enumerated() {
            let cell = JSONLD.Term.blankNode(cells[idx])
            let firstObject: JSONLD.Term
            if case .object(let inner) = item {
                if inner["@value"] != nil {
                    firstObject = objectFromValue(inner)
                } else {
                    firstObject = emitNode(inner, graphName: graphName)
                }
            } else {
                firstObject = .literal(JSONLD.Literal(value: ""))
            }
            emitQuad(subject: cell, predicate: .iri(Self.rdfFirst), object: firstObject, graph: graphName)
            let rest: JSONLD.Term = idx == items.count - 1 ? .iri(Self.rdfNil) : .blankNode(cells[idx + 1])
            emitQuad(subject: cell, predicate: .iri(Self.rdfRest), object: rest, graph: graphName)
        }
        return .blankNode(cells[0])
    }

    /// True when this term, lexically, would survive serialization to
    /// N-Quads as a well-formed RDF term per [RFC 3987 IRI](https://www.rfc-editor.org/rfc/rfc3987)
    /// + [BCP 47 language tag](https://www.rfc-editor.org/rfc/bcp47).
    func isWellFormed(term: JSONLD.Term) -> Bool {
        switch term {
        case .iri(let s): return RDFTerm.isWellFormedIRI(s)
        case .blankNode: return true
        case .literal(let lit):
            if !RDFTerm.isWellFormedIRI(lit.datatype) { return false }
            if let lang = lit.language, !RDFTerm.isWellFormedLanguageTag(lang) { return false }
            return true
        }
    }

    func expandToStringArray(_ value: JSONLD.JSON) -> [String] {
        switch value {
        case .string(let s): return [s]
        case .array(let arr):
            return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        default: return []
        }
    }

    mutating func emitQuad(subject: JSONLD.Term, predicate: JSONLD.Term, object: JSONLD.Term, graph: JSONLD.Term?) {
        // Well-formed RDF check ([JSON-LD 1.1 API §10](https://www.w3.org/TR/json-ld11-api/#deserialize-json-ld-to-rdf-algorithm)).
        // Drop quads with malformed IRIs (in any slot), invalid
        // language tags, or invalid graph names.
        guard isWellFormed(term: subject),
              isWellFormed(term: predicate),
              isWellFormed(term: object),
              graph.map(isWellFormed(term:)) ?? true
        else { return }

        let quad = JSONLD.Quad(subject: subject, predicate: predicate, object: object, graph: graph)
        if let graph {
            let key: String
            switch graph {
            case .iri(let iri): key = iri
            case .blankNode(let id): key = id
            case .literal: key = "_:literal-graph"
            }
            dataset.namedGraphs[key, default: []].append(quad)
        } else {
            dataset.defaultGraph.append(quad)
        }
    }
}
