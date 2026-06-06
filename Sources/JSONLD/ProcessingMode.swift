extension JSONLD {
    /// JSON-LD processing mode.
    ///
    /// Controls which version of the JSON-LD specification the processor
    /// applies. Set via the `@version` keyword in a context, or via the
    /// `processingMode` option on individual API calls.
    ///
    /// See [JSON-LD 1.1 API §3.1](https://www.w3.org/TR/json-ld11-api/#dom-jsonldoptions-processingmode).
    public enum ProcessingMode: String, Sendable, Hashable, CaseIterable {
        case jsonLd10 = "json-ld-1.0"
        case jsonLd11 = "json-ld-1.1"
    }
}
