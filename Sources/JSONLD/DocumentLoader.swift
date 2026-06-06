import Foundation

extension JSONLD {
    /// A remote document fetched by a `DocumentLoader`.
    ///
    /// See [JSON-LD 1.1 API §6.2](https://www.w3.org/TR/json-ld11-api/#remotedocument).
    public struct RemoteDocument: Sendable, Hashable {
        /// The MIME type the loader resolved the document with, e.g.
        /// `"application/ld+json"`.
        public var contentType: String
        /// The final IRI the document was loaded from, after any
        /// HTTP redirects.
        public var documentURL: URL
        /// The parsed JSON document body.
        public var document: JSONLD.JSON
        /// IRI of an external context referenced by HTTP `Link` header
        /// with `rel="http://www.w3.org/ns/json-ld#context"`, if any.
        public var contextURL: URL?
        /// The associated profile parameter from the `Link` header,
        /// if any.
        public var profile: String?

        /// Build a `RemoteDocument` from a loader's parsed response.
        public init(
            contentType: String,
            documentURL: URL,
            document: JSONLD.JSON,
            contextURL: URL? = nil,
            profile: String? = nil
        ) {
            self.contentType = contentType
            self.documentURL = documentURL
            self.document = document
            self.contextURL = contextURL
            self.profile = profile
        }
    }
}

/// Loads remote JSON-LD documents (and their contexts) by IRI.
///
/// `Sendable`-bound and `async`. The default implementation is
/// ``URLSessionDocumentLoader`` (URLSession-backed with an
/// actor-isolated LRU cache). Provide your own implementation to pin
/// contexts to local fixtures, mock network access in tests, or enforce
/// a content-security policy.
///
/// Pass an instance via ``JSONLD/Options/documentLoader``; without one,
/// any string `@context` reference throws ``JSONLD/Error/loadingRemoteContextFailed(_:)``.
public protocol JSONLDDocumentLoader: Sendable {
    /// Fetch the document at `url` and return it as a parsed
    /// ``JSONLD/RemoteDocument``.
    ///
    /// Implementations should throw ``JSONLD/Error/loadingDocumentFailed(_:)``
    /// on transport failures and ``JSONLD/Error/loadingRemoteContextFailed(_:)``
    /// when the response is reachable but unparseable as JSON.
    func load(url: URL) async throws -> JSONLD.RemoteDocument
}
