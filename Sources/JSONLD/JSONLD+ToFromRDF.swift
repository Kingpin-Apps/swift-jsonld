import Foundation

extension JSONLD {
    /// Convert a JSON-LD document to an RDF dataset.
    ///
    /// See [JSON-LD 1.1 API §10](https://www.w3.org/TR/json-ld11-api/#deserialize-json-ld-to-rdf-algorithm).
    /// Expands the input, then walks the result to produce
    /// subject-predicate-object-graph quads. Use ``JSONLD/NQuads`` to
    /// serialize the result to a string.
    ///
    /// - Parameters:
    ///   - input: The JSON-LD input document.
    ///   - options: Algorithm options.
    /// - Returns: An RDF dataset (default graph + named graphs).
    public static func toRDF(
        _ input: JSON,
        options: Options = Options()
    ) async throws(JSONLD.Error) -> Dataset {
        if let limit = options.maxNestingDepth {
            try checkNestingDepth(input, limit: limit)
        }
        let expanded = try await expand(input, options: options)
        return toRDF(expanded: expanded)
    }

    /// Throws when `input` nests arrays or objects deeper than `limit`.
    /// Iterative, so the check itself cannot overflow the stack.
    static func checkNestingDepth(_ input: JSON, limit: Int) throws(JSONLD.Error) {
        var stack: [(JSON, Int)] = [(input, 1)]
        while let (value, depth) = stack.popLast() {
            switch value {
            case .array(let items):
                guard depth <= limit else { throw depthError(limit) }
                for item in items { stack.append((item, depth + 1)) }
            case .object(let map):
                guard depth <= limit else { throw depthError(limit) }
                for item in map.values { stack.append((item, depth + 1)) }
            default:
                break
            }
        }
    }

    private static func depthError(_ limit: Int) -> JSONLD.Error {
        .other(code: "nesting too deep", message: "input nests arrays or objects deeper than \(limit) levels")
    }

    /// Convert an RDF dataset to a JSON-LD document.
    ///
    /// See [JSON-LD 1.1 API §11](https://www.w3.org/TR/json-ld11-api/#serialize-rdf-as-json-ld-algorithm).
    /// Inverse of ``toRDF(_:options:)``. Set
    /// ``JSONLD/Options/useNativeTypes`` to coerce XSD-typed literals
    /// into native JSON values; set ``JSONLD/Options/useRdfType`` to
    /// preserve `rdf:type` predicates instead of collapsing them into
    /// `@type`.
    ///
    /// - Parameters:
    ///   - dataset: The RDF dataset to serialize.
    ///   - options: Algorithm options.
    /// - Returns: A JSON-LD document in expanded form.
    public static func fromRDF(
        _ dataset: Dataset,
        options: Options = Options()
    ) async throws(JSONLD.Error) -> JSON {
        return try fromRDF(dataset: dataset, options: options)
    }
}
