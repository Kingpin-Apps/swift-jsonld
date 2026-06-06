import Foundation

extension JSONLD {
    /// Expand a JSON-LD document into its most explicit form.
    ///
    /// See [JSON-LD 1.1 API §3.1.2](https://www.w3.org/TR/json-ld11-api/#dom-jsonldprocessor-expand).
    /// Expansion resolves every term against its active context, replaces
    /// compact IRIs with absolute ones, and reshapes value objects into
    /// the canonical `{"@value": …, "@type": …}` form. The result depends
    /// only on the semantics of the input, never on its syntactic
    /// choices (term names, container shapes, abbreviations).
    ///
    /// Pass an inline context via ``JSONLD/Options/expandContext``;
    /// remote `@context` URIs are dereferenced through
    /// ``JSONLD/Options/documentLoader``.
    ///
    /// - Parameters:
    ///   - input: The JSON-LD input document.
    ///   - options: Algorithm options. Use the default `Options()` for
    ///     basic processing.
    /// - Returns: The expanded form — always an array of expanded node
    ///   objects (possibly empty).
    public static func expand(
        _ input: JSON,
        options: Options = Options()
    ) async throws(JSONLD.Error) -> JSON {
        var ctx = ActiveContext(
            processingMode: options.processingMode,
            baseIRI: options.base
        )

        if let expandCtx = options.expandContext {
            ctx = try await processContext(
                activeContext: ctx,
                localContext: expandCtx,
                baseURL: options.base,
                options: options
            )
        }

        let expanded = try await expand(
            activeContext: ctx,
            activeProperty: nil,
            element: input,
            baseURL: options.base,
            frameExpansion: false,
            ordered: options.ordered,
            fromMap: false,
            options: options
        )

        switch expanded {
        case .null: return .array([])
        case .array: return expanded
        default: return .array([expanded])
        }
    }
}
