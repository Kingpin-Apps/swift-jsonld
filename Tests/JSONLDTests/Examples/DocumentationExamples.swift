// Tests backing every code example shipped in README.md and the
// DocC catalog (Sources/JSONLD/JSONLD.docc/). The body of each `@Test`
// block is the exact code that appears in the docs — if a snippet
// drifts from reality, this suite breaks.
//
// Run with: swift test --filter "Documentation examples"

import Foundation
import Testing
import JSONLD

@Suite("Documentation examples")
struct DocumentationExamples {

    // MARK: - expand

    @Test("Expand resolves terms to absolute IRIs")
    func expandExample() async throws {
        let input: JSONLD.JSON = [
            "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
            "name": "Alice",
        ]

        let expanded = try await JSONLD.expand(input)

        #expect(expanded == .array([
            .object([
                "http://xmlns.com/foaf/0.1/name": .array([
                    .object(["@value": "Alice"])
                ])
            ])
        ]))
    }

    // MARK: - compact

    @Test("Compact folds absolute IRIs back to terms")
    func compactExample() async throws {
        let input: JSONLD.JSON = [
            .object([
                "http://xmlns.com/foaf/0.1/name": .array([
                    .object(["@value": "Alice"])
                ])
            ])
        ]
        let context: JSONLD.JSON = ["name": "http://xmlns.com/foaf/0.1/name"]

        let compacted = try await JSONLD.compact(input, context: context)

        #expect(compacted == .object([
            "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
            "name": "Alice",
        ]))
    }

    // MARK: - flatten

    @Test("Flatten hoists nested nodes to the top level")
    func flattenExample() async throws {
        let input: JSONLD.JSON = [
            "@context": ["@vocab": "http://example.org/"],
            "@id": "http://example.org/alice",
            "name": "Alice",
            "knows": .object([
                "@id": "http://example.org/bob",
                "name": "Bob",
            ]),
        ]
        let context: JSONLD.JSON = ["@vocab": "http://example.org/"]

        let flat = try await JSONLD.flatten(input, context: context)

        guard case .object(let m) = flat,
              case .array(let graph) = m["@graph"]
        else {
            Issue.record("flatten output should be {@context, @graph: [...]}")
            return
        }
        // Two top-level nodes: alice (with a knows-ref to bob) and bob.
        #expect(graph.count == 2)
    }

    // MARK: - frame

    @Test("Frame selects nodes by @type")
    func frameExample() async throws {
        let input: JSONLD.JSON = [
            "@context": ["@vocab": "http://example.org/"],
            "@graph": .array([
                .object(["@id": "ex:alice", "@type": "Person", "name": "Alice"]),
                .object(["@id": "ex:rover", "@type": "Animal", "name": "Rover"]),
            ]),
        ]
        let frame: JSONLD.JSON = [
            "@context": ["@vocab": "http://example.org/"],
            "@type": "Person",
        ]

        let framed = try await JSONLD.frame(input, frame: frame)

        // Only the Person node should survive.
        guard case .object(let m) = framed else {
            Issue.record("expected object result")
            return
        }
        // The frame output is either a single node or a {@graph: [...]} wrapper.
        if case .array(let nodes) = m["@graph"] {
            #expect(nodes.count == 1)
            if case .object(let alice) = nodes[0] {
                #expect(alice["@type"] == "Person" || alice["@type"] == .array(["Person"]))
            }
        } else {
            #expect(m["@type"] == "Person" || m["@type"] == .array(["Person"]))
        }
    }

    // MARK: - toRDF

    @Test("toRDF produces quads serializable to N-Quads")
    func toRDFExample() async throws {
        let input: JSONLD.JSON = [
            "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
            "@id": "http://example.org/alice",
            "name": "Alice",
        ]

        let dataset = try await JSONLD.toRDF(input)
        let nquads = JSONLD.NQuads.serialize(dataset)

        #expect(nquads == "<http://example.org/alice> <http://xmlns.com/foaf/0.1/name> \"Alice\" .\n")
    }

    // MARK: - fromRDF

    @Test("fromRDF parses N-Quads back into JSON-LD")
    func fromRDFExample() async throws {
        let nquads = "<http://example.org/alice> <http://xmlns.com/foaf/0.1/name> \"Alice\" .\n"

        let dataset = try JSONLD.NQuads.parseDataset(nquads)
        let json = try await JSONLD.fromRDF(dataset)

        // fromRDF yields an array of expanded nodes.
        guard case .array(let nodes) = json, nodes.count == 1,
              case .object(let alice) = nodes[0]
        else {
            Issue.record("expected one expanded node")
            return
        }
        #expect(alice["@id"] == "http://example.org/alice")
    }

    // MARK: - canonize

    @Test("canonize emits stable N-Quads, blank-node labels rewritten")
    func canonizeExample() async throws {
        let input: JSONLD.JSON = [
            "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
            "name": "Alice",
        ]

        let canonical = try await JSONLD.canonize(input)

        // Single quad, blank-node subject renamed to _:c14n0.
        #expect(canonical == "_:c14n0 <http://xmlns.com/foaf/0.1/name> \"Alice\" .\n")
    }

    @Test("Two semantically-equivalent docs canonize identically")
    func canonizeStability() async throws {
        let a: JSONLD.JSON = [
            "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
            "@id": "http://example.org/alice",
            "name": "Alice",
        ]
        // Same data, but written with the absolute IRI instead of the term.
        let b: JSONLD.JSON = [
            "@id": "http://example.org/alice",
            "http://xmlns.com/foaf/0.1/name": "Alice",
        ]

        let ca = try await JSONLD.canonize(a)
        let cb = try await JSONLD.canonize(b)

        #expect(ca == cb)
    }

    // MARK: - DocumentLoader wiring (no network)

    @Test("URLSessionDocumentLoader can be plugged in via Options")
    func documentLoaderWiring() async throws {
        // This snippet shows wiring only — we don't make a real network
        // request. The loader is constructed and assigned; the inline
        // context in the document lets expand succeed without ever
        // hitting the loader.
        var options = JSONLD.Options()
        options.documentLoader = URLSessionDocumentLoader()

        let input: JSONLD.JSON = [
            "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
            "name": "Alice",
        ]

        let expanded = try await JSONLD.expand(input, options: options)
        #expect(!(expanded == .array([])))
    }
}
