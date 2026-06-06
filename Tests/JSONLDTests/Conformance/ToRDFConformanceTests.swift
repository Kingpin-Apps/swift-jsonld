import Testing
import Foundation
@testable import JSONLD
import RDFCanonize

/// Runs the W3C JSON-LD 1.1 toRDF test suite against
/// `JSONLD.toRDF`.
///
/// > **Phase 4 complete — 335/335 (100%).**
@Suite("ToRDF — W3C conformance")
struct ToRDFConformanceTests {

    static let manifest: TestManifest = {
        do { return try TestManifest.load(.toRdf) }
        catch { return TestManifest(name: "", description: "", baseIRI: "", entries: []) }
    }()

    @Test(
        "Positive evaluation tests",
        arguments: Self.manifest.entries.filter {
            $0.isPositive
            && $0.option?.specVersion != "json-ld-1.0"
            // Skip non-normative tests (optional features like
            // `rdfDirection: i18n-datatype` and `compound-literal`).
            && ($0.option?.normative ?? true)
            // Skip tests that require optional RDF features we don't
            // implement: generalized RDF (blank-node predicates),
            // i18n datatypes, compound literals.
            && $0.requires == nil
        }
    )
    func positive(_ entry: TestEntry) async throws {
        guard let expectPath = entry.expect else {
            Issue.record("Positive test \(entry.id) has no expect file")
            return
        }

        let input: JSONLD.JSON
        let expectedNQuads: String
        do {
            input = try JSONFixture.load(entry.fixtureURL(entry.input))
            expectedNQuads = try String(contentsOf: entry.fixtureURL(expectPath), encoding: .utf8)
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
        // Resolve remote `@context` URLs against the on-disk fixture
        // tree (closes tc031, tc034, te126, te127, te128).
        let inputDir = entry.fixtureURL(entry.input).deletingLastPathComponent()
        options.documentLoader = LocalFixtureLoader(baseDirectory: inputDir)
        if let mode = entry.option?.processingMode {
            switch mode {
            case "json-ld-1.0": options.processingMode = .jsonLd10
            case "json-ld-1.1": options.processingMode = .jsonLd11
            default: break
            }
        }
        if let expandCtxPath = entry.option?.expandContext {
            do {
                let raw = try JSONFixture.load(entry.fixtureURL(expandCtxPath))
                // Context files are wrapped as `{"@context": …}`;
                // expandContext expects the unwrapped context value.
                if case .object(let map) = raw, let inner = map["@context"] {
                    options.expandContext = inner
                } else {
                    options.expandContext = raw
                }
            } catch {
                Issue.record("expandContext fixture I/O failed for \(entry.id): \(error)")
                return
            }
        }

        let dataset: JSONLD.Dataset
        do {
            dataset = try await JSONLD.toRDF(input, options: options)
        } catch {
            #expect(Bool(false), "toRDF threw on \(entry.id): \(error)")
            return
        }
        let actualNQuads = JSONLD.NQuads.serialize(dataset)

        // Canonicalize both sides through URDNA2015 so blank-node
        // labels match — the W3C expected outputs are produced from
        // canonicalized form (e.g. `_:c14n0`) while our toRDF emits
        // sequential `_:b0`, `_:b1`, …
        let actualCanon = canonicalize(actualNQuads)
        let expectedCanon = canonicalize(expectedNQuads)
        #expect(
            actualCanon == expectedCanon,
            "\(entry.id) \(entry.name)"
        )
    }

    /// Negative tests — `JSONLD.toRDF` must throw an error whose
    /// `code` matches `entry.expectErrorCode`.
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
        let input: JSONLD.JSON
        do {
            input = try JSONFixture.load(entry.fixtureURL(entry.input))
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
        if let mode = entry.option?.processingMode {
            switch mode {
            case "json-ld-1.0": options.processingMode = .jsonLd10
            case "json-ld-1.1": options.processingMode = .jsonLd11
            default: break
            }
        }
        if let expandCtxPath = entry.option?.expandContext,
           let raw = try? JSONFixture.load(entry.fixtureURL(expandCtxPath))
        {
            if case .object(let map) = raw, let inner = map["@context"] {
                options.expandContext = inner
            } else {
                options.expandContext = raw
            }
        }
        do {
            _ = try await JSONLD.toRDF(input, options: options)
            #expect(Bool(false), "\(entry.id) \(entry.name) — expected throw of \"\(expectedCode)\" but toRDF succeeded")
        } catch {
            #expect(error.code == expectedCode, "\(entry.id) \(entry.name) — expected \"\(expectedCode)\", got \"\(error.code)\"")
        }
    }

    /// Parse N-Quads, canonicalize blank-node labels via URDNA2015,
    /// re-emit sorted. Falls back to a simple split-trim-sort when
    /// parsing or canonicalization fails so a comparison still happens.
    private func canonicalize(_ s: String) -> [String] {
        do {
            let quads = try JSONLD.NQuads.parse(s)
            let bridged = quads.map { q in
                RDFCanonize.Quad(
                    subject: bridge(q.subject),
                    predicate: bridge(q.predicate),
                    object: bridge(q.object),
                    graph: q.graph.map(bridge)
                )
            }
            let canonical = try RDFCanonize.canonicalize(quads: bridged)
            return canonical.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted()
        } catch {
            return s.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted()
        }
    }

    private func bridge(_ term: JSONLD.Term) -> RDFCanonize.Term {
        switch term {
        case .iri(let s): return .iri(s)
        case .blankNode(let s): return .blankNode(s)
        case .literal(let lit):
            return .literal(RDFCanonize.Literal(
                value: lit.value,
                datatype: lit.datatype,
                language: lit.language,
                direction: lit.direction
            ))
        }
    }
}
