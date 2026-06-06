import Foundation

extension JSONLD {
    /// The processed definition of a single term in an active context.
    ///
    /// See [JSON-LD 1.1 §9 "Data Structures"](https://www.w3.org/TR/json-ld11-api/#dfn-term-definition).
    /// Term definitions are produced by the
    /// [Create Term Definition](https://www.w3.org/TR/json-ld11-api/#create-term-definition)
    /// algorithm and consumed by every other algorithm in the spec.
    public struct TermDefinition: Sendable, Hashable {
        /// Absolute IRI, blank node identifier, or keyword that this
        /// term expands to. May be `nil` if the term has been
        /// explicitly unmapped (see `nullMapping`).
        public var iriMapping: String?

        /// `true` when the term has been *explicitly* unmapped via
        /// `{"@id": null}` or by a bare-value `null`. Differentiates
        /// "deliberate" nil from "not yet set" — explicit nulls block
        /// the vocab/document-relative fallbacks during IRI expansion.
        public var nullMapping: Bool = false

        /// Set if this term may be used as a compact-IRI prefix (i.e.
        /// `term:suffix` resolves to `iriMapping + suffix`).
        public var prefixFlag: Bool = false

        /// Set if redefining this term in a later context must be
        /// rejected (unless `override-protected` is in effect).
        public var `protected`: Bool = false

        /// True if this term defines a reverse property (`@reverse`).
        public var reverseProperty: Bool = false

        /// Base URL associated with this term definition — used when
        /// dereferencing a scoped `@context` that contains relative IRIs.
        public var baseURL: URL?

        /// The local context attached to this term via `@context`
        /// (i.e. a scoped context). Stored raw — applied during
        /// expansion when the term is entered.
        public var localContext: JSONLD.JSON?

        /// Set of container mappings (`@container` value, normalized).
        /// May contain combinations like `[@set, @id]`. Empty if the
        /// term has no container mapping.
        public var containerMapping: Set<ContainerKind> = []

        /// Direction mapping (`@direction`). `nil` means "unset";
        /// `.null` means "explicitly unset, overriding context default".
        public var directionMapping: DirectionMapping?

        /// Index mapping (`@index`) — only meaningful when the
        /// container mapping includes `@index`.
        public var indexMapping: String?

        /// Language mapping (`@language`). `nil` means "unset";
        /// `.null` means "explicitly unset".
        public var languageMapping: LanguageMapping?

        /// Type mapping (`@type`) — an absolute IRI, keyword (`@id`,
        /// `@vocab`, `@json`, `@none`), or `nil` if unset.
        public var typeMapping: String?

        /// Nest value (`@nest`) — either `@nest` itself or a term that
        /// expands to `@nest`. Drives JSON-LD's nesting feature.
        public var nestValue: String?

        public init(iriMapping: String? = nil) {
            self.iriMapping = iriMapping
        }

        /// A direction mapping value. JSON-LD distinguishes "no
        /// mapping" from "explicitly null mapping" — Swift's `nil`
        /// covers the former, this enum carries the latter.
        public enum DirectionMapping: Sendable, Hashable {
            case ltr
            case rtl
            case null
        }

        /// A language mapping value. `nil` (on the field) means "no
        /// mapping"; `.null` here means "explicitly unmapped".
        public enum LanguageMapping: Sendable, Hashable {
            case tag(String)
            case null
        }
    }
}
