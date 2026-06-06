import Foundation
import RDFCanonize

extension JSONLD {
    /// Canonicalize a JSON-LD document — `normalize` / `canonize` in
    /// the spec's vocabulary.
    ///
    /// Expands the input, converts it to an RDF dataset, then runs
    /// [RDFC-1.0 / URDNA2015](https://www.w3.org/TR/rdf-canon/) via
    /// [swift-rdf-canonize](https://github.com/Kingpin-Apps/swift-rdf-canonize)
    /// to produce a stable N-Quads serialization. Two documents that
    /// are semantically equivalent produce byte-identical output —
    /// canonicalization is the prerequisite step for hashing or signing
    /// linked-data documents.
    ///
    /// - Parameters:
    ///   - input: The JSON-LD input document.
    ///   - options: Algorithm options.
    /// - Returns: Canonical N-Quads as a UTF-8 string.
    public static func canonize(
        _ input: JSON,
        options: Options = Options()
    ) async throws(JSONLD.Error) -> String {
        let dataset = try await toRDF(input, options: options)
        let bridged = bridgeToCanonize(dataset)
        do {
            return try RDFCanonize.canonicalize(quads: bridged)
        } catch {
            throw JSONLD.Error.other(
                code: "canonicalize-failed",
                message: "\(error)"
            )
        }
    }

    /// Translate our internal `Dataset` to `swift-rdf-canonize`'s
    /// quad model. The two type hierarchies are intentionally
    /// kept separate so each package's surface stays clean — this
    /// is the only place they cross.
    private static func bridgeToCanonize(_ dataset: Dataset) -> [RDFCanonize.Quad] {
        dataset.allQuads.map { quad in
            RDFCanonize.Quad(
                subject: bridge(quad.subject),
                predicate: bridge(quad.predicate),
                object: bridge(quad.object),
                graph: quad.graph.map(bridge)
            )
        }
    }

    private static func bridge(_ term: Term) -> RDFCanonize.Term {
        switch term {
        case .iri(let s): return .iri(s)
        case .blankNode(let s): return .blankNode(s)
        case .literal(let lit):
            return .literal(RDFCanonize.Literal(
                value: lit.value,
                datatype: lit.datatype,
                language: lit.language,
                direction: lit.direction
            ))
        }
    }
}
