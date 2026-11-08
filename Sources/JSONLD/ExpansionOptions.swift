import Foundation

extension JSONLD {
    /// Options accepted by every JSON-LD algorithm.
    ///
    /// See [JSON-LD 1.1 API §4.1 "JsonLdOptions"](https://www.w3.org/TR/json-ld11-api/#dom-jsonldoptions).
    /// Not every option is honoured at every build phase — see the
    /// per-field doc comments for which phase wires each in.
    public struct Options: Sendable {
        /// Base IRI used to resolve relative IRIs in document content
        /// and remote contexts.
        public var base: URL?

        /// Default processing mode. Individual contexts may upgrade
        /// (1.0 → 1.1) via `@version` but cannot downgrade.
        public var processingMode: ProcessingMode = .jsonLd11

        /// An inline `@context` document to use during expansion in
        /// addition to any embedded in the input.
        public var expandContext: JSON?

        /// Pluggable remote-document loader. Set to enable string
        /// `@context` dereferencing during expansion / compaction /
        /// framing. Without a loader, a string `@context` throws
        /// `loadingRemoteContextFailed`.
        public var documentLoader: (any JSONLDDocumentLoader)?

        /// Cap on remote context dereferences during a single
        /// algorithm invocation. Exceeded depth throws
        /// `maxRemoteContextsExceeded`.
        public var maxRemoteContextsLoaded: Int = 50

        /// If true, expansion throws when it would silently drop an
        /// object key whose term does not expand to a keyword or an
        /// absolute IRI (an unmapped term, or a term mapped to `null`),
        /// and RDF conversion throws when it would drop a quad with an
        /// ill-formed IRI, language tag or datatype. Use it before
        /// hashing or signing a document, so that every key a reader
        /// sees is covered by the canonical form.
        public var safeMode: Bool = false

        /// Work factor passed to RDFC-1.0 canonicalization in
        /// ``JSONLD/canonize(_:options:)``. `Int.max` (the default) is
        /// unbounded and suits trusted input. For untrusted input use a
        /// small value (jsonld.js maps low/medium/high to 0/2/3); poison
        /// graphs then fail fast with a `canonicalize-failed` error.
        public var canonicalizationWorkFactor: Int = .max

        /// Maximum nesting depth of arrays and objects accepted by
        /// ``JSONLD/toRDF(_:options:)`` and ``JSONLD/canonize(_:options:)``.
        /// `nil` (the default) applies no limit. RDF conversion recurses
        /// once per nesting level, so untrusted input should set a bound
        /// that fits the calling thread's stack.
        public var maxNestingDepth: Int? = nil

        /// If true, produce arrays for keys whose container mapping is
        /// `@set`. Compaction option, threaded through expand options
        /// so a single ``Options`` value flows through every algorithm.
        public var compactArrays: Bool = true

        /// Ordered output. Stable but slower; useful for deterministic
        /// snapshots and W3C test comparisons.
        public var ordered: Bool = false

        /// `fromRDF` option: if true, convert XSD-typed literals
        /// (boolean, integer, double) into native JSON values rather
        /// than `{"@value": ..., "@type": ...}` objects. Default false.
        public var useNativeTypes: Bool = false

        /// `fromRDF` option: if true, leave `rdf:type` predicates as
        /// regular IRI keys rather than collapsing them into `@type`.
        /// Default false.
        public var useRdfType: Bool = false

        // MARK: - Framing options

        /// `frame()` embedding policy.
        ///
        /// See [JSON-LD 1.1 Framing §4.2](https://www.w3.org/TR/json-ld11-framing/#dfn-embed-flag).
        /// 1.0-only `@first`/`@last` are intentionally omitted.
        public enum FrameEmbed: String, Sendable, Hashable {
            case always = "@always"
            case once = "@once"
            case never = "@never"
            case link = "@link"
            // 1.0 legacy; behavioral spec: last occurrence embeds,
            // earlier ones become bare `{"@id": …}` references.
            case last = "@last"
            // 1.0 legacy alias: synonymous with `@once` (first wins).
            case first = "@first"
        }

        /// Default `@embed` flag value. Overridden per frame by an
        /// inline `@embed` key.
        public var embed: FrameEmbed = .once

        /// `@explicit` default. When true, only properties named in the
        /// frame appear in the output.
        public var explicit: Bool = false

        /// `@requireAll` default. When true, every non-keyword property
        /// in the frame must match (AND), instead of any (OR).
        public var requireAll: Bool = false

        /// `@omitDefault` default. When true, `@default` values for
        /// unmatched properties are suppressed.
        public var omitDefault: Bool = false

        /// If non-nil, override the spec default for omitting the
        /// outer `@graph` wrapper. Resolved at `frame()` entry:
        /// processing mode 1.1 → `true`, 1.0 → `false`.
        public var omitGraph: Bool? = nil

        /// If true, frame against the default graph; otherwise frame
        /// against a merged view of all named graphs.
        public var frameDefault: Bool = false

        /// Whether to drop blank-node identifiers that are referenced
        /// exactly once after framing. When `nil`, the spec default
        /// applies: `true` for processing mode 1.1, `false` for 1.0.
        /// Set explicitly to override.
        public var pruneBlankNodeIdentifiers: Bool? = nil

        /// Build a default `Options` value. Override fields directly to
        /// customise.
        public init() {}
    }
}
