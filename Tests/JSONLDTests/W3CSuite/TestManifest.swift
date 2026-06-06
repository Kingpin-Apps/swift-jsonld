import Foundation

/// Decoded W3C JSON-LD test manifest (e.g. `expand-manifest.jsonld`).
///
/// Manifests are themselves JSON-LD documents. We treat them as plain
/// JSON for parsing — the keys we care about (`name`, `sequence`,
/// `baseIri`) are unambiguous without going through the JSON-LD
/// algorithms (which would be circular).
struct TestManifest: Decodable, Sendable, Hashable {
    let name: String
    let description: String
    let baseIRI: String
    let entries: [TestEntry]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case baseIRI = "baseIri"
        case entries = "sequence"
    }
}

/// A single test case within a manifest.
struct TestEntry: Decodable, Sendable, Hashable, CustomStringConvertible {
    /// Fragment identifier like `"#t0001"`.
    let id: String
    /// Type IRIs — combination of evaluation-class and operation
    /// (e.g. `["jld:PositiveEvaluationTest", "jld:ExpandTest"]`).
    let types: [String]
    /// Human-readable test name.
    let name: String
    /// Description of what behaviour the test verifies.
    let purpose: String?
    /// Relative path to the input document (resolved against the
    /// manifest's directory).
    let input: String
    /// Relative path to the expected output. Present on
    /// `PositiveEvaluationTest` entries.
    let expect: String?
    /// Relative path to a context document, used by `CompactTest`
    /// and `FlattenTest` entries.
    let context: String?
    /// Relative path to a frame document, used by `FrameTest` entries.
    let frame: String?
    /// Spec error code that the algorithm must raise. Present on
    /// `NegativeEvaluationTest` entries.
    let expectErrorCode: String?
    /// Per-test option overrides (spec version, base IRI, processing
    /// mode, etc.).
    let option: TestOption?
    /// Optional-feature gate. When set, the test requires the named
    /// feature (e.g. `GeneralizedRdf`, `I18nDatatype`, `CompoundLiteral`).
    /// Processors that don't implement that feature skip the entry.
    let requires: String?

    enum CodingKeys: String, CodingKey {
        case id = "@id"
        case types = "@type"
        case name
        case purpose
        case input
        case expect
        case context
        case frame
        case expectErrorCode
        case option
        case requires
    }

    var isPositive: Bool { types.contains("jld:PositiveEvaluationTest") }
    var isNegative: Bool { types.contains("jld:NegativeEvaluationTest") }

    var description: String { "\(id) \(name)" }
}

/// Per-test option overrides, as defined in the manifest's
/// [test vocabulary](https://w3c.github.io/json-ld-api/tests/vocab.html).
///
/// All fields are optional — manifests only set what differs from the
/// processor defaults. New option keys are added as the conformance
/// suite evolves; unknown keys are ignored by `Decodable`.
struct TestOption: Decodable, Sendable, Hashable {
    let specVersion: String?
    let base: String?
    let processingMode: String?
    let expandContext: String?
    let compactArrays: Bool?
    let useNativeTypes: Bool?
    let useRdfType: Bool?
    let produceGeneralizedRdf: Bool?
    let rdfDirection: String?
    let normative: Bool?
    // Framing-specific (frame-manifest.jsonld).
    let omitGraph: Bool?
    let embed: String?
    let explicit: Bool?
    let requireAll: Bool?
    let frameDefault: Bool?
    let pruneBlankNodeIdentifiers: Bool?
    let ordered: Bool?
}
