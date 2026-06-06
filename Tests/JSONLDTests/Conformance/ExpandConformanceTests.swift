import Testing
import Foundation
@testable import JSONLD

/// Runs the W3C JSON-LD 1.1 expand test suite against `JSONLD.expand`.
///
/// > **Phase 2 complete — 273/273 (100%).**
@Suite("Expand — W3C conformance")
struct ExpandConformanceTests {

    static let manifest: TestManifest = {
        do { return try TestManifest.load(.expand) }
        catch { return TestManifest(name: "", description: "", baseIRI: "", entries: []) }
    }()

    /// Each entry runs as its own Swift Testing test case.
    @Test(
        "Positive evaluation tests",
        arguments: Self.manifest.entries.filter { $0.isPositive && $0.option?.specVersion != "json-ld-1.0" }
    )
    func positive(_ entry: TestEntry) async throws {
        guard let expectPath = entry.expect else {
            Issue.record("Positive test \(entry.id) has no expect file")
            return
        }

        let input: JSONLD.JSON
        let expected: JSONLD.JSON
        do {
            let rawInput = try JSONFixture.load(entry.fixtureURL(entry.input))
            // Inline any remote @context references before handing off
            // to the (sync-internals) expand algorithm.
            let inputDir = entry.fixtureURL(entry.input).deletingLastPathComponent()
            input = try InlineRemoteContexts.inline(rawInput, baseDir: inputDir)
            expected = try JSONFixture.load(entry.fixtureURL(expectPath))
        } catch {
            // Fixture loading is infrastructure, not algorithm — fail loudly.
            Issue.record("Fixture I/O failed for \(entry.id): \(error)")
            return
        }

        var options = JSONLD.Options()
        // Per-test base IRI: the document URL the W3C suite would have
        // served. Built from the manifest's baseIri + the input path.
        // Tests can override with explicit option.base.
        if let optionBase = entry.option?.base {
            options.base = URL(string: optionBase)
        } else if let manifestBase = URL(string: Self.manifest.baseIRI) {
            options.base = URL(string: entry.input, relativeTo: manifestBase)?.absoluteURL
        }
        // Resolve remote `@context` URLs against the on-disk fixture tree.
        let docDir = entry.fixtureURL(entry.input).deletingLastPathComponent()
        options.documentLoader = LocalFixtureLoader(baseDirectory: docDir)
        if let mode = entry.option?.processingMode {
            switch mode {
            case "json-ld-1.0": options.processingMode = .jsonLd10
            case "json-ld-1.1": options.processingMode = .jsonLd11
            default: break
            }
        }
        // Test option may point at a context file to expand against.
        if let expandCtxPath = entry.option?.expandContext {
            if let loaded = try? JSONFixture.load(entry.fixtureURL(expandCtxPath)) {
                if case .object(let m) = loaded, let inner = m["@context"] {
                    options.expandContext = inner
                } else {
                    options.expandContext = loaded
                }
            }
        }

        let actual: JSONLD.JSON
        do {
            actual = try await JSONLD.expand(input, options: options)
        } catch {
            // Algorithm threw on a positive test → fail. Reported, not
            // recorded, so we count it explicitly.
            #expect(Bool(false), "expand threw on \(entry.id) (\(entry.name)): \(error)")
            return
        }

        #expect(actual == expected, "\(entry.id) \(entry.name)")
    }

    /// Negative tests — the algorithm must throw an error whose code
    /// matches `entry.expectErrorCode`. See
    /// [JSON-LD 1.1 API §6](https://www.w3.org/TR/json-ld11-api/#jsonlderrorcode).
    @Test(
        "Negative evaluation tests",
        arguments: Self.manifest.entries.filter {
            $0.isNegative && $0.option?.specVersion != "json-ld-1.0"
        }
    )
    func negative(_ entry: TestEntry) async throws {
        guard let expectedCode = entry.expectErrorCode else {
            Issue.record("Negative test \(entry.id) has no expectErrorCode")
            return
        }
        let input: JSONLD.JSON
        do {
            let rawInput = try JSONFixture.load(entry.fixtureURL(entry.input))
            let inputDir = entry.fixtureURL(entry.input).deletingLastPathComponent()
            input = try InlineRemoteContexts.inline(rawInput, baseDir: inputDir)
        } catch {
            Issue.record("Fixture I/O failed for \(entry.id): \(error)")
            return
        }

        var options = JSONLD.Options()
        if let optionBase = entry.option?.base {
            options.base = URL(string: optionBase)
        } else if let manifestBase = URL(string: Self.manifest.baseIRI) {
            options.base = URL(string: entry.input, relativeTo: manifestBase)?.absoluteURL
        }
        let docDir = entry.fixtureURL(entry.input).deletingLastPathComponent()
        options.documentLoader = LocalFixtureLoader(baseDirectory: docDir)
        if let mode = entry.option?.processingMode {
            switch mode {
            case "json-ld-1.0": options.processingMode = .jsonLd10
            case "json-ld-1.1": options.processingMode = .jsonLd11
            default: break
            }
        }
        if let expandCtxPath = entry.option?.expandContext {
            if let loaded = try? JSONFixture.load(entry.fixtureURL(expandCtxPath)) {
                if case .object(let m) = loaded, let inner = m["@context"] {
                    options.expandContext = inner
                } else {
                    options.expandContext = loaded
                }
            }
        }

        do {
            _ = try await JSONLD.expand(input, options: options)
            #expect(Bool(false), "\(entry.id) \(entry.name) — expected throw of \"\(expectedCode)\" but expand succeeded")
        } catch {
            #expect(error.code == expectedCode, "\(entry.id) \(entry.name) — expected \"\(expectedCode)\", got \"\(error.code)\"")
        }
    }
}
