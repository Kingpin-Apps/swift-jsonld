import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// URLSession is unavailable on platforms without a network stack
// (notably wasm/WASI). On those targets the loader and its helper
// are compiled out; users supply their own ``JSONLDDocumentLoader``.
#if canImport(Darwin) || canImport(FoundationNetworking)

/// Default `JSONLDDocumentLoader` backed by URLSession.
///
/// Fetches `application/ld+json`, `application/json`, and
/// `application/xhtml+xml` resources over HTTP/HTTPS. Honours
/// (best-effort) the `Link` header for external `@context`
/// references — see [JSON-LD 1.1 §6.1](https://www.w3.org/TR/json-ld11/#interpreting-json-as-json-ld).
///
/// Backed by an `actor`-isolated LRU cache to amortise repeated
/// fetches of the same context. The cache is bounded by entry
/// count, not byte size.
public final class URLSessionDocumentLoader: JSONLDDocumentLoader, @unchecked Sendable {
    private let session: URLSession
    private let cache: Cache

    /// Build a loader.
    ///
    /// - Parameters:
    ///   - session: The URLSession to fetch with. Defaults to `.shared`.
    ///   - cacheCapacity: Maximum number of documents to retain in the
    ///     LRU cache, by entry count (not by byte size).
    public init(
        session: URLSession = .shared,
        cacheCapacity: Int = 64
    ) {
        self.session = session
        self.cache = Cache(capacity: cacheCapacity)
    }

    public func load(url: URL) async throws -> JSONLD.RemoteDocument {
        if let cached = await cache.get(url) { return cached }

        var request = URLRequest(url: url)
        request.setValue(
            "application/ld+json, application/json;q=0.9, */*;q=0.5",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")
            ?? "application/octet-stream"
        let finalURL = httpResponse?.url ?? url

        let parsed = try JSONFixtureForLoader.toJSON(
            try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        )

        // Best-effort Link-header extraction. Full RFC-8288 parsing
        // is its own can of worms; this picks up the common JSON-LD
        // context-link form.
        var contextURL: URL? = nil
        if let link = httpResponse?.value(forHTTPHeaderField: "Link"),
           link.contains("http://www.w3.org/ns/json-ld#context"),
           let urlMatch = link.range(of: #"<([^>]+)>"#, options: .regularExpression)
        {
            let inside = link[urlMatch].dropFirst().dropLast()
            contextURL = URL(string: String(inside), relativeTo: finalURL)?.absoluteURL
        }

        let doc = JSONLD.RemoteDocument(
            contentType: contentType,
            documentURL: finalURL,
            document: parsed,
            contextURL: contextURL,
            profile: nil
        )
        await cache.put(url, doc)
        return doc
    }

    private actor Cache {
        let capacity: Int
        private var order: [URL] = []
        private var entries: [URL: JSONLD.RemoteDocument] = [:]

        init(capacity: Int) { self.capacity = capacity }

        func get(_ url: URL) -> JSONLD.RemoteDocument? {
            guard let doc = entries[url] else { return nil }
            // Touch — move to most-recent.
            order.removeAll { $0 == url }
            order.append(url)
            return doc
        }

        func put(_ url: URL, _ doc: JSONLD.RemoteDocument) {
            entries[url] = doc
            order.removeAll { $0 == url }
            order.append(url)
            while order.count > capacity {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
    }
}

/// Local JSON-from-Foundation helper. Mirrors the test target's
/// `JSONFixture` (test files can't be imported from product code).
private enum JSONFixtureForLoader {
    static func toJSON(_ any: Any) throws -> JSONLD.JSON {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            if String(cString: n.objCType) == "c" { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d.truncatingRemainder(dividingBy: 1) == 0,
               d >= Double(Int64.min), d <= Double(Int64.max)
            { return .int(Int64(d)) }
            return .double(d)
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(try arr.map(toJSON)) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONLD.JSON] = [:]
            for (k, v) in dict { out[k] = try toJSON(v) }
            return .object(out)
        }
        struct UnsupportedType: Error { let kind: String }
        throw UnsupportedType(kind: String(describing: type(of: any)))
    }
}

#endif // canImport(Darwin) || canImport(FoundationNetworking)
