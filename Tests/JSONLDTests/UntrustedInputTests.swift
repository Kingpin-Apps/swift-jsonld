import Foundation
import Testing
@testable import JSONLD

/// Options for canonicalizing untrusted documents before they are
/// hashed or signed.
@Suite("Untrusted input options")
struct UntrustedInputTests {
    private static let vocab: JSONLD.JSON = ["@vocab": "https://example.com/v#"]

    @Test("Whole-number doubles canonicalize as xsd:integer, like integers")
    func wholeNumberDouble() async throws {
        let asDouble = try await JSONLD.canonize(["@context": Self.vocab, "x": .double(1.0)])
        let asInt = try await JSONLD.canonize(["@context": Self.vocab, "x": .int(1)])
        #expect(asDouble == asInt)
        #expect(asDouble.contains("\"1\"^^<http://www.w3.org/2001/XMLSchema#integer>"))
        let fractional = try await JSONLD.canonize(["@context": Self.vocab, "x": .double(1.5)])
        #expect(fractional.contains("\"1.5E0\"^^<http://www.w3.org/2001/XMLSchema#double>"))
        let huge = try await JSONLD.canonize(["@context": Self.vocab, "x": .double(1e19)])
        #expect(huge.contains("\"10000000000000000000\"^^<http://www.w3.org/2001/XMLSchema#integer>"))
    }

    @Test("Safe mode rejects keys that expansion would drop")
    func safeMode() async throws {
        let unmapped: JSONLD.JSON = ["@context": ["a": "https://example.com/a"], "a": "kept", "b": "dropped"]
        var options = JSONLD.Options()
        _ = try await JSONLD.canonize(unmapped)
        options.safeMode = true
        await #expect(throws: JSONLD.Error.self) { _ = try await JSONLD.canonize(unmapped, options: options) }
        let nulled: JSONLD.JSON = ["@context": ["@vocab": "https://example.com/v#", "c": .null], "c": "hidden"]
        await #expect(throws: JSONLD.Error.self) { _ = try await JSONLD.canonize(nulled, options: options) }
        let mapped: JSONLD.JSON = ["@context": Self.vocab, "a": "x"]
        _ = try await JSONLD.canonize(mapped, options: options)
    }

    @Test("Safe mode rejects terms that RDF conversion would drop")
    func safeModeIllFormedTerms() async throws {
        var options = JSONLD.Options()
        options.safeMode = true
        let space: JSONLD.JSON = ["@context": ["p": "https://example.com/v#x y"], "p": "hidden"]
        let blankPredicate: JSONLD.JSON = ["@context": ["p": "_:hidden"], "p": "hidden"]
        let badLanguage: JSONLD.JSON = [
            "@context": Self.vocab,
            "t": ["@value": "hidden", "@language": "x y"],
        ]
        for doc in [space, blankPredicate, badLanguage] {
            _ = try await JSONLD.canonize(doc)
            await #expect(throws: JSONLD.Error.self) { _ = try await JSONLD.canonize(doc, options: options) }
        }
        let wellFormed: JSONLD.JSON = ["@context": Self.vocab, "t": ["@value": "kept", "@language": "en"]]
        _ = try await JSONLD.canonize(wellFormed, options: options)
        // An unmapped @type term (as in the CIP-100 example) still passes.
        let relativeType: JSONLD.JSON = ["@context": ["a": "https://example.com/a"], "@type": "Other", "a": "x"]
        _ = try await JSONLD.canonize(relativeType, options: options)
    }

    @Test("A finite work factor stops a poison document quickly")
    func workFactor() async throws {
        let leaf: JSONLD.JSON = ["q": "x"]
        let star: JSONLD.JSON = ["p": .array(Array(repeating: leaf, count: 10))]
        let doc: JSONLD.JSON = ["@context": Self.vocab, "@graph": [star, star]]
        var options = JSONLD.Options()
        options.canonicalizationWorkFactor = 2
        let start = ContinuousClock.now
        await #expect(throws: JSONLD.Error.self) { _ = try await JSONLD.canonize(doc, options: options) }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("maxNestingDepth rejects deep input before recursing")
    func nestingDepth() async throws {
        var deep: JSONLD.JSON = "x"
        for _ in 0..<200 { deep = ["a": deep] }
        var options = JSONLD.Options()
        options.maxNestingDepth = 64
        let doc: JSONLD.JSON = ["@context": Self.vocab, "b": deep]
        await #expect(throws: JSONLD.Error.self) { _ = try await JSONLD.canonize(doc, options: options) }
        var shallow: JSONLD.JSON = "x"
        for _ in 0..<10 { shallow = ["a": shallow] }
        _ = try await JSONLD.canonize(["@context": Self.vocab, "b": shallow], options: options)
    }
}
