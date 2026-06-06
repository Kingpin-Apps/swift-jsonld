import Testing
import Foundation
@testable import JSONLD

/// Runs the W3C JSON-LD 1.1 flatten test suite against
/// `JSONLD.flatten`.
///
/// > **Phase 3 complete — 54/54 (100%).**
@Suite("Flatten — W3C conformance")
struct FlattenConformanceTests {

    static let manifest: TestManifest = {
        do { return try TestManifest.load(.flatten) }
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

        let input: JSONLD.JSON
        let expected: JSONLD.JSON
        do {
            input = try JSONFixture.load(entry.fixtureURL(entry.input))
            expected = try JSONFixture.load(entry.fixtureURL(expectPath))
        } catch {
            Issue.record("Fixture I/O failed for \(entry.id): \(error)")
            return
        }

        // Some flatten tests carry a context fixture used for the
        // final compaction step.
        let contextValue: JSONLD.JSON?
        if let ctxPath = entry.context {
            do {
                let raw = try JSONFixture.load(entry.fixtureURL(ctxPath))
                if case .object(let m) = raw, let inner = m["@context"] {
                    contextValue = inner
                } else {
                    contextValue = raw
                }
            } catch {
                Issue.record("context fixture I/O failed for \(entry.id): \(error)")
                return
            }
        } else {
            contextValue = nil
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
            actual = try await JSONLD.flatten(input, context: contextValue, options: options)
        } catch {
            #expect(Bool(false), "flatten threw on \(entry.id): \(error)")
            return
        }
        #expect(
            equalStructurally(actual, expected),
            "\(entry.id) \(entry.name)"
        )
    }

    /// Negative tests — `JSONLD.flatten` must throw an error whose
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
        let input: JSONLD.JSON
        do {
            input = try JSONFixture.load(entry.fixtureURL(entry.input))
        } catch {
            Issue.record("Fixture I/O failed for \(entry.id): \(error)")
            return
        }
        let contextValue: JSONLD.JSON?
        if let ctxPath = entry.context,
           let raw = try? JSONFixture.load(entry.fixtureURL(ctxPath))
        {
            if case .object(let m) = raw, let inner = m["@context"] {
                contextValue = inner
            } else {
                contextValue = raw
            }
        } else {
            contextValue = nil
        }
        var options = JSONLD.Options()
        if let optionBase = entry.option?.base {
            options.base = URL(string: optionBase)
        } else if let manifestBase = URL(string: Self.manifest.baseIRI) {
            options.base = URL(string: entry.input, relativeTo: manifestBase)?.absoluteURL
        }
        let inputDir = entry.fixtureURL(entry.input).deletingLastPathComponent()
        options.documentLoader = LocalFixtureLoader(baseDirectory: inputDir)
        do {
            _ = try await JSONLD.flatten(input, context: contextValue, options: options)
            #expect(Bool(false), "\(entry.id) \(entry.name) — expected throw of \"\(expectedCode)\" but flatten succeeded")
        } catch {
            #expect(error.code == expectedCode, "\(entry.id) \(entry.name) — expected \"\(expectedCode)\", got \"\(error.code)\"")
        }
    }

    /// Structural JSON equality, key-order independent.
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
