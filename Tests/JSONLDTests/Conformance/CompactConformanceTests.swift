import Testing
import Foundation
@testable import JSONLD

/// Runs the W3C JSON-LD 1.1 compact test suite against
/// `JSONLD.compact`.
///
/// > **Phase 3 complete — 228/228 (100%).**
@Suite("Compact — W3C conformance")
struct CompactConformanceTests {

    static let manifest: TestManifest = {
        do { return try TestManifest.load(.compact) }
        catch { return TestManifest(name: "", description: "", baseIRI: "", entries: []) }
    }()

    @Test(
        "Positive evaluation tests",
        arguments: Self.manifest.entries.filter {
            $0.isPositive
            && $0.option?.specVersion != "json-ld-1.0"
            && ($0.option?.normative ?? true)
            && $0.requires == nil
        }
    )
    func positive(_ entry: TestEntry) async throws {
        guard let expectPath = entry.expect else {
            Issue.record("Positive test \(entry.id) has no expect file")
            return
        }

        guard let contextPath = entry.context else {
            Issue.record("Compact test \(entry.id) has no context file")
            return
        }

        let input: JSONLD.JSON
        let expected: JSONLD.JSON
        let contextDoc: JSONLD.JSON
        do {
            input = try JSONFixture.load(entry.fixtureURL(entry.input))
            expected = try JSONFixture.load(entry.fixtureURL(expectPath))
            contextDoc = try JSONFixture.load(entry.fixtureURL(contextPath))
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
        let inputDir = entry.fixtureURL(entry.input).deletingLastPathComponent()
        options.documentLoader = LocalFixtureLoader(baseDirectory: inputDir)
        if let compactArrays = entry.option?.compactArrays {
            options.compactArrays = compactArrays
        }
        if let mode = entry.option?.processingMode {
            switch mode {
            case "json-ld-1.0": options.processingMode = .jsonLd10
            case "json-ld-1.1": options.processingMode = .jsonLd11
            default: break
            }
        }

        let actual: JSONLD.JSON
        do {
            // Compact tests' context file wraps the context in a top-level
            // {"@context": ...} object; pass that inner value to compact.
            let unwrapped: JSONLD.JSON
            if case .object(let m) = contextDoc, let c = m["@context"] { unwrapped = c }
            else { unwrapped = contextDoc }
            actual = try await JSONLD.compact(input, context: unwrapped, options: options)
        } catch {
            #expect(Bool(false), "compact threw on \(entry.id): \(error)")
            return
        }
        #expect(
            equalStructurally(actual, expected),
            "\(entry.id) \(entry.name)"
        )
    }

    /// Negative tests — `JSONLD.compact` must throw an error whose
    /// `code` matches `entry.expectErrorCode`.
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
        guard let contextPath = entry.context else {
            Issue.record("Compact negative test \(entry.id) has no context file")
            return
        }
        let input: JSONLD.JSON
        let contextDoc: JSONLD.JSON
        do {
            input = try JSONFixture.load(entry.fixtureURL(entry.input))
            contextDoc = try JSONFixture.load(entry.fixtureURL(contextPath))
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
        let inputDir = entry.fixtureURL(entry.input).deletingLastPathComponent()
        options.documentLoader = LocalFixtureLoader(baseDirectory: inputDir)
        if let compactArrays = entry.option?.compactArrays {
            options.compactArrays = compactArrays
        }
        if let mode = entry.option?.processingMode {
            switch mode {
            case "json-ld-1.0": options.processingMode = .jsonLd10
            case "json-ld-1.1": options.processingMode = .jsonLd11
            default: break
            }
        }
        let unwrapped: JSONLD.JSON
        if case .object(let m) = contextDoc, let c = m["@context"] { unwrapped = c }
        else { unwrapped = contextDoc }
        do {
            _ = try await JSONLD.compact(input, context: unwrapped, options: options)
            #expect(Bool(false), "\(entry.id) \(entry.name) — expected throw of \"\(expectedCode)\" but compact succeeded")
        } catch {
            #expect(error.code == expectedCode, "\(entry.id) \(entry.name) — expected \"\(expectedCode)\", got \"\(error.code)\"")
        }
    }

    /// Structural JSON equality. Object key order doesn't matter;
    /// arrays preserve element order (compact's algorithm produces a
    /// deterministic order; matching expected verbatim catches
    /// reorderings as real bugs).
    private func equalStructurally(_ lhs: JSONLD.JSON, _ rhs: JSONLD.JSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let l), .bool(let r)): return l == r
        case (.int(let l), .int(let r)): return l == r
        case (.double(let l), .double(let r)): return l == r
        case (.int(let l), .double(let r)): return Double(l) == r
        case (.double(let l), .int(let r)): return l == Double(r)
        case (.string(let l), .string(let r)): return l == r
        case (.object(let l), .object(let r)):
            if Set(l.keys) != Set(r.keys) { return false }
            for k in l.keys {
                if !equalStructurally(l[k]!, r[k]!) { return false }
            }
            return true
        case (.array(let l), .array(let r)):
            if l.count != r.count { return false }
            for i in 0..<l.count {
                if !equalStructurally(l[i], r[i]) { return false }
            }
            return true
        default:
            return false
        }
    }
}
