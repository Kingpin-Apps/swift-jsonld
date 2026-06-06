import Foundation

extension JSONLD {
    /// An RDF dataset: a default graph plus zero or more named graphs.
    ///
    /// See [RDF 1.1 Concepts §4](https://www.w3.org/TR/rdf11-concepts/#section-dataset).
    /// JSON-LD's [Deserialize JSON-LD to RDF Algorithm (§10)](https://www.w3.org/TR/json-ld11-api/#deserialize-json-ld-to-rdf-algorithm)
    /// produces a `Dataset`; the [Serialize RDF as JSON-LD Algorithm
    /// (§11)](https://www.w3.org/TR/json-ld11-api/#serialize-rdf-as-json-ld-algorithm)
    /// consumes one.
    public struct Dataset: Sendable, Hashable {
        /// The default graph — triples not associated with a named graph.
        public var defaultGraph: [Quad] = []
        /// Named graphs, keyed by their graph-name IRI or blank-node id.
        public var namedGraphs: [String: [Quad]] = [:]

        public init() {}

        /// All quads across the default + named graphs, default graph first.
        public var allQuads: [Quad] {
            var out = defaultGraph
            for name in namedGraphs.keys.sorted() {
                out.append(contentsOf: namedGraphs[name] ?? [])
            }
            return out
        }
    }

    /// A single RDF quad: subject + predicate + object + graph.
    ///
    /// When `graph` is `nil` the quad belongs to the default graph;
    /// otherwise it belongs to the named graph identified by the
    /// graph-name IRI or blank-node id.
    public struct Quad: Sendable, Hashable {
        public var subject: Term
        public var predicate: Term
        public var object: Term
        public var graph: Term?

        public init(subject: Term, predicate: Term, object: Term, graph: Term? = nil) {
            self.subject = subject
            self.predicate = predicate
            self.object = object
            self.graph = graph
        }
    }

    /// An RDF term: an IRI, a blank node, or a literal.
    public enum Term: Sendable, Hashable {
        case iri(String)
        case blankNode(String)
        case literal(Literal)
    }

    /// An RDF literal: lexical value + datatype IRI + optional
    /// language tag and base direction.
    ///
    /// See [RDF 1.1 Concepts §3.3](https://www.w3.org/TR/rdf11-concepts/#section-Graph-Literal).
    public struct Literal: Sendable, Hashable {
        /// Lexical form (the string representation).
        public var value: String
        /// Datatype IRI. Use `xsd:string` for plain string literals.
        public var datatype: String
        /// Optional language tag (BCP 47). When set, datatype must be
        /// `rdf:langString`.
        public var language: String?
        /// Optional base direction (`"ltr"` or `"rtl"`). 1.1 only.
        public var direction: String?

        public static let xsdString = "http://www.w3.org/2001/XMLSchema#string"
        public static let xsdBoolean = "http://www.w3.org/2001/XMLSchema#boolean"
        public static let xsdInteger = "http://www.w3.org/2001/XMLSchema#integer"
        public static let xsdDouble = "http://www.w3.org/2001/XMLSchema#double"
        public static let rdfLangString = "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"
        public static let rdfJSON = "http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON"

        public init(
            value: String,
            datatype: String = Literal.xsdString,
            language: String? = nil,
            direction: String? = nil
        ) {
            self.value = value
            self.datatype = datatype
            self.language = language
            self.direction = direction
        }
    }
}
