import Foundation

extension JSONLD {
    /// Compact a JSON-LD document against a target context.
    ///
    /// See [JSON-LD 1.1 API §3.1.1](https://www.w3.org/TR/json-ld11-api/#dom-jsonldprocessor-compact).
    /// Compaction is the reverse of ``JSONLD/expand(_:options:)`` — it
    /// folds absolute IRIs back to terms, collapses single-value arrays
    /// when appropriate, and wraps the result in the target `@context`.
    /// The input may be in any shape — `compact` expands it first to
    /// normalize.
    ///
    /// - Parameters:
    ///   - input: Any JSON-LD document; compacted internally before output.
    ///   - context: The target context for compaction. Pass an inline
    ///     object, a remote URL as a string, or an array combining the
    ///     two.
    ///   - options: Algorithm options.
    /// - Returns: A compacted JSON-LD document whose root is an object
    ///   carrying the target `@context`.
    public static func compact(
        _ input: JSON,
        context: JSON,
        options: Options = Options()
    ) async throws(JSONLD.Error) -> JSON {
        // First expand the input so we have a normalized starting form.
        let expanded = try await expand(input, options: options)

        // Process the target context.
        let baseCtx = ActiveContext(
            processingMode: options.processingMode,
            baseIRI: options.base
        )
        let ctx = try await processContext(
            activeContext: baseCtx,
            localContext: context,
            baseURL: options.base,
            options: options
        )

        let inverse = InverseContext(ctx)
        let compacted = try await compact(
            activeContext: ctx,
            activeProperty: nil,
            element: expanded,
            compactArrays: options.compactArrays,
            ordered: options.ordered,
            inverse: inverse,
            options: options
        )

        // Wrap the result in the target context for round-trip
        // serialization. Empty contexts (`{}`, `[]`, `null`) are
        // dropped from the output — jsonld.js does the same.
        let contextIsEmpty: Bool = {
            switch context {
            case .object(let m): return m.isEmpty
            case .array(let a): return a.isEmpty
            case .null: return true
            default: return false
            }
        }()
        switch compacted {
        case .array(let items) where items.isEmpty:
            return .object([:])
        case .object(var map):
            if !contextIsEmpty { map["@context"] = context }
            return .object(map)
        case .array(let items) where items.count == 1:
            // `compactArrays: false` retains the wrapping `@graph`
            // even for a single-element document.
            if options.compactArrays, case .object(var map) = items[0] {
                if !contextIsEmpty { map["@context"] = context }
                return .object(map)
            }
            var out: [String: JSON] = [
                try inverse.compact("@graph", activeContext: ctx): .array(items),
            ]
            if !contextIsEmpty { out["@context"] = context }
            return .object(out)
        default:
            var out: [String: JSON] = [
                try inverse.compact("@graph", activeContext: ctx): compacted,
            ]
            if !contextIsEmpty { out["@context"] = context }
            return .object(out)
        }
    }
}
