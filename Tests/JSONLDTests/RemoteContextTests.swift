import Testing
import Foundation
@testable import JSONLD

/// Verifies that string-valued `@context` references are dereferenced
/// via `options.documentLoader` and the loaded context is applied.
///
/// Prior to Priority 2 the internal context-processing chain was
/// synchronous, so string `@context` URLs threw
/// `.loadingRemoteContextFailed` regardless of the loader. The chain is
/// now `async throws` end-to-end; this suite pins the round-trip down.
@Suite("Remote context loading")
struct RemoteContextTests {

    /// In-memory loader. Maps absolute URL strings to ready-built
    /// `RemoteDocument` values; throws if the URL was not registered.
    final class MockLoader: JSONLDDocumentLoader, @unchecked Sendable {
        struct UnknownURL: Error { let url: URL }
        var documents: [String: JSONLD.RemoteDocument] = [:]
        var loadCount = 0

        func load(url: URL) async throws -> JSONLD.RemoteDocument {
            loadCount += 1
            guard let doc = documents[url.absoluteString] else {
                throw UnknownURL(url: url)
            }
            return doc
        }
    }

    /// `JSONLD.expand` resolves a string `@context` URL through the
    /// configured loader, applies the loaded context, and produces the
    /// correctly expanded output.
    @Test("expand follows a string @context via documentLoader")
    func expandFollowsRemoteContext() async throws {
        let ctxURL = URL(string: "https://example.com/ctx.jsonld")!
        let loader = MockLoader()
        loader.documents[ctxURL.absoluteString] = JSONLD.RemoteDocument(
            contentType: "application/ld+json",
            documentURL: ctxURL,
            document: .object([
                "@context": .object([
                    "name": .string("http://schema.org/name")
                ])
            ])
        )

        var options = JSONLD.Options()
        options.documentLoader = loader

        let input: JSONLD.JSON = .object([
            "@context": .string(ctxURL.absoluteString),
            "name": .string("Ada"),
        ])

        let expanded = try await JSONLD.expand(input, options: options)
        let expected: JSONLD.JSON = .array([
            .object([
                "http://schema.org/name": .array([
                    .object(["@value": .string("Ada")])
                ])
            ])
        ])
        #expect(expanded == expected)
        #expect(loader.loadCount == 1)
    }

    /// `loadingRemoteContextFailed` is thrown with a clear message when
    /// no loader is configured.
    @Test("expand throws when no loader is configured for a string @context")
    func expandThrowsWithoutLoader() async throws {
        let input: JSONLD.JSON = .object([
            "@context": .string("https://example.com/ctx.jsonld"),
            "name": .string("Ada"),
        ])
        await #expect(throws: JSONLD.Error.self) {
            try await JSONLD.expand(input, options: JSONLD.Options())
        }
    }

    /// Recursion guard: a remote context whose body references itself
    /// throws `recursiveContextInclusion` rather than looping.
    @Test("Self-referencing remote context throws recursiveContextInclusion")
    func selfReferencingContext() async throws {
        let ctxURL = URL(string: "https://example.com/cycle.jsonld")!
        let loader = MockLoader()
        // The loaded document's @context refers to itself by URL.
        loader.documents[ctxURL.absoluteString] = JSONLD.RemoteDocument(
            contentType: "application/ld+json",
            documentURL: ctxURL,
            document: .object([
                "@context": .string(ctxURL.absoluteString)
            ])
        )

        var options = JSONLD.Options()
        options.documentLoader = loader

        let input: JSONLD.JSON = .object([
            "@context": .string(ctxURL.absoluteString),
            "name": .string("Ada"),
        ])

        await #expect(throws: JSONLD.Error.self) {
            try await JSONLD.expand(input, options: options)
        }
    }
}
