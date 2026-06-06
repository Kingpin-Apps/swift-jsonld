extension JSONLD {
    /// Errors thrown by JSON-LD algorithms.
    ///
    /// Cases mirror the error codes defined in
    /// [JSON-LD 1.1 API §6](https://www.w3.org/TR/json-ld11-api/#jsonlderrorcode).
    /// Each case carries a short message identifying the offending
    /// input (an IRI, keyword, or term). Use ``code`` to compare against
    /// the spec's string error codes.
    ///
    /// Cases not yet promoted to first-class enum entries surface via
    /// ``other(code:message:)``, carrying the spec error code verbatim.
    public enum Error: Swift.Error, Sendable, Equatable {
        // Context processing
        case invalidLocalContext(String)
        case invalidRemoteContext(String)
        case invalidContextNullification(String)
        case recursiveContextInclusion(String)
        case contextOverflow(String)
        case maxRemoteContextsExceeded
        case processingModeConflict(String)

        // Term definitions
        case invalidIRIMapping(String)
        case invalidKeywordAlias(String)
        case invalidTermDefinition(String)
        case invalidTypeMapping(String)
        case invalidReverseProperty(String)
        case cyclicIRIMapping(String)

        // Document loading
        case loadingDocumentFailed(String)
        case loadingRemoteContextFailed(String)

        /// Catch-all for spec error codes that haven't been promoted to
        /// their own enum case yet. `code` carries the
        /// [JSON-LD 1.1 API §6](https://www.w3.org/TR/json-ld11-api/#jsonlderrorcode)
        /// error code string verbatim; `message` is a short human-readable
        /// description of the offending input.
        case other(code: String, message: String)

        /// The W3C [JSON-LD 1.1 API §6](https://www.w3.org/TR/json-ld11-api/#jsonlderrorcode)
        /// error code for this error. Used by the W3C negative-test
        /// harness to match `expectErrorCode` from test manifests.
        public var code: String {
            switch self {
            case .invalidLocalContext: return "invalid local context"
            case .invalidRemoteContext: return "invalid remote context"
            case .invalidContextNullification: return "invalid context nullification"
            case .recursiveContextInclusion: return "recursive context inclusion"
            case .contextOverflow: return "context overflow"
            case .maxRemoteContextsExceeded: return "loading remote context failed"
            case .processingModeConflict: return "processing mode conflict"
            case .invalidIRIMapping: return "invalid IRI mapping"
            case .invalidKeywordAlias: return "invalid keyword alias"
            case .invalidTermDefinition: return "invalid term definition"
            case .invalidTypeMapping: return "invalid type mapping"
            case .invalidReverseProperty: return "invalid reverse property"
            case .cyclicIRIMapping: return "cyclic IRI mapping"
            case .loadingDocumentFailed: return "loading document failed"
            case .loadingRemoteContextFailed: return "loading remote context failed"
            case .other(let code, _): return code
            }
        }
    }
}
