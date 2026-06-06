import Foundation
@testable import JSONLD

/// `JSONLDDocumentLoader` that resolves URLs to on-disk fixture files
/// rooted at a specific test-suite directory.
///
/// Used by the conformance harnesses so the real Priority-2 async
/// remote-context path executes end-to-end. The pre-existing
/// `InlineRemoteContexts` walker only handles simple cases; this loader
/// handles subdirectory paths, scoped `@context` inside term definitions,
/// and cyclic / shared remote contexts (cycle detection lives in
/// `processContext` itself).
///
/// URL → path resolution:
/// 1. If the URL's `lastPathComponent` matches a file in `baseDirectory`,
///    return that.
/// 2. Otherwise treat the URL's path as relative to `baseDirectory` and
///    follow it (used by the `e126-context.jsonld` → `../e126-…`
///    style references inside loaded contexts).
final class LocalFixtureLoader: JSONLDDocumentLoader, @unchecked Sendable {
    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    func load(url: URL) async throws -> JSONLD.RemoteDocument {
        let candidate = resolve(url: url)
        let document = try JSONFixture.load(candidate)
        return JSONLD.RemoteDocument(
            contentType: "application/ld+json",
            documentURL: URL(fileURLWithPath: candidate.path),
            document: document
        )
    }

    /// Map an arbitrary URL onto the fixture tree. The W3C suite uses
    /// `https://w3c.github.io/...` base IRIs but our fixtures sit on
    /// disk under `Tests/JSONLDTests/json-ld-{api,framing}/tests/`. We
    /// strip everything before the manifest-test prefix and join the
    /// remainder against `baseDirectory`.
    private func resolve(url: URL) -> URL {
        // Already a file URL pointing into the suite — pass through.
        if url.isFileURL { return url }

        let lastTwo = url.pathComponents.suffix(2)
        if lastTwo.count == 2 {
            let subdir = String(lastTwo.first!)
            let file = String(lastTwo.last!)
            let subdirCandidate = baseDirectory
                .appendingPathComponent(subdir)
                .appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: subdirCandidate.path) {
                return subdirCandidate
            }
        }
        let direct = baseDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        // Fall through to the direct path even if missing — the load
        // attempt will surface a clear I/O error rather than silently
        // recover with a wrong document.
        return direct
    }
}
