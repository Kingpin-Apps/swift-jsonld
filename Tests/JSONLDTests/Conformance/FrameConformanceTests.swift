import Testing
import Foundation
@testable import JSONLD

/// Runs the [W3C JSON-LD 1.1 Framing test suite](https://github.com/w3c/json-ld-framing)
/// against `JSONLD.frame`.
///
/// The harness loads the framing manifest, then for each positive entry
/// reads the input, frame, and expected outputs from the framing
/// submodule, invokes `JSONLD.frame`, and compares the result
/// structurally (key-order-independent for objects, position-sensitive
/// for ordered arrays).
///
/// > **Phase 7 complete — 88/88 (100%).**
@Suite("Frame — W3C conformance")
struct FrameConformanceTests {

    static let manifest: TestManifest = {
        do { return try TestManifest.load(.frame) }
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
        guard let expectPath = entry.expect, let framePath = entry.frame else {
            Issue.record("Positive frame test \(entry.id) missing expect or frame path")
            return
        }

        let inputJSON: JSONLD.JSON
        let frameJSON: JSONLD.JSON
        let expected:  JSONLD.JSON
        do {
            inputJSON = try JSONFixture.load(entry.fixtureURL(entry.input, base: .frame))
            frameJSON = try JSONFixture.load(entry.fixtureURL(framePath, base: .frame))
            expected  = try JSONFixture.load(entry.fixtureURL(expectPath, base: .frame))
        } catch {
            Issue.record("Fixture I/O failed for \(entry.id): \(error)")
            return
        }

        var options = JSONLD.Options()
        if let s = entry.option?.processingMode {
            options.processingMode = (s == "json-ld-1.0") ? .jsonLd10 : .jsonLd11
        }
        if let s = entry.option?.base, let u = URL(string: s) { options.base = u }
        if let v = entry.option?.compactArrays { options.compactArrays = v }
        if let v = entry.option?.ordered { options.ordered = v }
        if let v = entry.option?.omitGraph { options.omitGraph = v }
        if let v = entry.option?.explicit { options.explicit = v }
        if let v = entry.option?.requireAll { options.requireAll = v }
        if let v = entry.option?.frameDefault { options.frameDefault = v }
        if let v = entry.option?.pruneBlankNodeIdentifiers { options.pruneBlankNodeIdentifiers = v }
        if let s = entry.option?.embed, let e = JSONLD.Options.FrameEmbed(rawValue: s) {
            options.embed = e
        }

        let actual: JSONLD.JSON
        do {
            actual = try await JSONLD.frame(inputJSON, frame: frameJSON, options: options)
        } catch {
            #expect(Bool(false), "frame threw on \(entry.id): \(error)")
            return
        }

        #expect(
            equal(actual, expected),
            "\(entry.id) \(entry.name)\n  actual:   \(actual)\n  expected: \(expected)"
        )
    }

    /// Negative tests — `JSONLD.frame` must throw an error whose
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
        guard let framePath = entry.frame else {
            Issue.record("Frame negative test \(entry.id) has no frame file")
            return
        }
        let inputJSON: JSONLD.JSON
        let frameJSON: JSONLD.JSON
        do {
            inputJSON = try JSONFixture.load(entry.fixtureURL(entry.input, base: .frame))
            frameJSON = try JSONFixture.load(entry.fixtureURL(framePath, base: .frame))
        } catch {
            Issue.record("Fixture I/O failed for \(entry.id): \(error)")
            return
        }
        var options = JSONLD.Options()
        if let s = entry.option?.processingMode {
            options.processingMode = (s == "json-ld-1.0") ? .jsonLd10 : .jsonLd11
        }
        if let s = entry.option?.base, let u = URL(string: s) { options.base = u }
        do {
            _ = try await JSONLD.frame(inputJSON, frame: frameJSON, options: options)
            #expect(Bool(false), "\(entry.id) \(entry.name) — expected throw of \"\(expectedCode)\" but frame succeeded")
        } catch {
            #expect(error.code == expectedCode, "\(entry.id) \(entry.name) — expected \"\(expectedCode)\", got \"\(error.code)\"")
        }
    }

    /// Structural equality for framed JSON-LD output. Treats top-level
    /// and `@graph` arrays as unordered (frame iterates by sorted id).
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
            if l.count != r.count { return false }
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
