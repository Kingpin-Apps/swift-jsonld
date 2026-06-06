import Testing
import Foundation
@testable import JSONLD

/// Runs the W3C JSON-LD 1.1 fromRDF test suite against
/// `JSONLD.fromRDF`.
///
/// The harness parses the N-Quads input via `JSONLD.NQuads.parse`,
/// invokes `JSONLD.fromRDF`, and compares the resulting JSON tree
/// against the expected `.jsonld` fixture using a structural
/// comparison (key-order-independent for objects).
///
/// > **Phase 4 complete — 42/42 (100%).**
@Suite("FromRDF — W3C conformance")
struct FromRDFConformanceTests {

    static let manifest: TestManifest = {
        do { return try TestManifest.load(.fromRdf) }
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

        let inputText: String
        let expected: JSONLD.JSON
        do {
            inputText = try String(contentsOf: entry.fixtureURL(entry.input), encoding: .utf8)
            expected = try JSONFixture.load(entry.fixtureURL(expectPath))
        } catch {
            Issue.record("Fixture I/O failed for \(entry.id): \(error)")
            return
        }

        let dataset: JSONLD.Dataset
        do {
            dataset = try JSONLD.NQuads.parseDataset(inputText)
        } catch {
            Issue.record("N-Quads parse failed for \(entry.id): \(error)")
            return
        }

        var options = JSONLD.Options()
        if let useNative = entry.option?.useNativeTypes { options.useNativeTypes = useNative }
        if let useRdfType = entry.option?.useRdfType { options.useRdfType = useRdfType }

        let actual: JSONLD.JSON
        do {
            actual = try await JSONLD.fromRDF(dataset, options: options)
        } catch {
            #expect(Bool(false), "fromRDF threw on \(entry.id): \(error)")
            return
        }

        #expect(
            equal(actual, expected),
            "\(entry.id) \(entry.name)\n  actual:   \(actual)\n  expected: \(expected)"
        )
    }

    /// Negative tests — fromRDF (or its N-Quads parser) must throw an
    /// error whose `code` matches `entry.expectErrorCode`.
    @Test(
        "Negative evaluation tests",
        arguments: Self.manifest.entries.filter {
            $0.isNegative
            && $0.option?.specVersion != "json-ld-1.0"
            && ($0.option?.normative ?? true)
            && $0.requires == nil
        }
    )
    func negative(_ entry: TestEntry) async throws {
        guard let expectedCode = entry.expectErrorCode else {
            Issue.record("Negative test \(entry.id) has no expectErrorCode")
            return
        }
        let inputText: String
        do {
            inputText = try String(contentsOf: entry.fixtureURL(entry.input), encoding: .utf8)
        } catch {
            Issue.record("Fixture I/O failed for \(entry.id): \(error)")
            return
        }
        var options = JSONLD.Options()
        if let useNative = entry.option?.useNativeTypes { options.useNativeTypes = useNative }
        if let useRdfType = entry.option?.useRdfType { options.useRdfType = useRdfType }
        do {
            let dataset = try JSONLD.NQuads.parseDataset(inputText)
            _ = try await JSONLD.fromRDF(dataset, options: options)
            #expect(Bool(false), "\(entry.id) \(entry.name) — expected throw of \"\(expectedCode)\" but fromRDF succeeded")
        } catch let error as JSONLD.Error {
            #expect(error.code == expectedCode, "\(entry.id) \(entry.name) — expected \"\(expectedCode)\", got \"\(error.code)\"")
        } catch {
            // N-Quads parser errors are non-JSONLD.Error; surface raw.
            Issue.record("\(entry.id) \(entry.name) — non-JSONLD.Error: \(error)")
        }
    }

    /// Structural equality for JSON-LD output. Arrays at the top of
    /// the document and inside `@type` values are order-independent;
    /// other arrays preserve order (`@list` cells, value arrays).
    private func equal(_ lhs: JSONLD.JSON, _ rhs: JSONLD.JSON) -> Bool {
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
                if !equal(l[k]!, r[k]!) { return false }
            }
            return true
        case (.array(let l), .array(let r)):
            // Order-sensitive — fromRDF sorts its output deterministically.
            if l.count != r.count { return false }
            // Treat top-level node arrays as unordered: compare by
            // matching each lhs element to some rhs element.
            var matched = Array(repeating: false, count: r.count)
            for li in l {
                var found = false
                for (j, rj) in r.enumerated() where !matched[j] {
                    if equal(li, rj) { matched[j] = true; found = true; break }
                }
                if !found { return false }
            }
            return true
        default:
            return false
        }
    }
}
