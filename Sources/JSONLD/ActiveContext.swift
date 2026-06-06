import Foundation

extension JSONLD {
    /// The runtime processing state carried through every JSON-LD
    /// algorithm.
    ///
    /// See [JSON-LD 1.1 §9 "Data Structures" — active context](https://www.w3.org/TR/json-ld11-api/#dfn-active-context).
    /// An active context is produced by the
    /// [Context Processing](https://www.w3.org/TR/json-ld11-api/#context-processing-algorithm)
    /// algorithm and consumed by expansion / compaction / framing.
    public struct ActiveContext: Sendable, Hashable {
        /// Processed term definitions, keyed by term.
        public var termDefinitions: [String: TermDefinition] = [:]

        /// Base IRI used to resolve relative IRIs in document content.
        public var baseIRI: URL?

        /// Original base IRI — set once at the start of processing and
        /// preserved across context resets (`@context: null`).
        public var originalBaseIRI: URL?

        /// Vocabulary mapping (`@vocab`) — an IRI used to resolve
        /// vocabulary-relative IRIs.
        public var vocabularyMapping: String?

        /// Default language tag (`@language`).
        public var defaultLanguage: String?

        /// Default base direction (`@direction`).
        public var defaultBaseDirection: TermDefinition.DirectionMapping?

        /// Previous active context — non-nil while a type-scoped
        /// context is in effect; used by some algorithms to revert.
        public var previousContext: Reference?

        /// True when `previousContext` was set up by an explicit
        /// `@type` activation on a node object — distinct from
        /// activation driven by a `@container: @type` typemap
        /// iteration. The two have different revert semantics during
        /// compaction: the explicit-@type case needs the inverse
        /// context rebuilt after a `previousContext` revert (tc021),
        /// while the typemap case must NOT rebuild because the
        /// typemap relies on the type-scoped term mappings surviving
        /// the `propagate: false` revert (tm007). Set at the
        /// activation site, NOT preserved through processContext.
        public var previousContextFromExplicitType: Bool = false

        /// JSON-LD processing mode in effect for this context.
        public var processingMode: ProcessingMode

        public init(
            processingMode: ProcessingMode = .jsonLd11,
            baseIRI: URL? = nil
        ) {
            self.processingMode = processingMode
            self.baseIRI = baseIRI
            self.originalBaseIRI = baseIRI
        }

        /// Reference wrapper so `ActiveContext` can carry an optional
        /// previous context without forming an infinite type. Indirect
        /// enum would also work; a reference type is clearer about the
        /// pointer-like semantics.
        public final class Reference: @unchecked Sendable, Hashable {
            public let context: ActiveContext
            public init(_ context: ActiveContext) { self.context = context }

            public static func == (lhs: Reference, rhs: Reference) -> Bool {
                lhs.context == rhs.context
            }
            public func hash(into hasher: inout Hasher) { hasher.combine(context) }
        }
    }
}
