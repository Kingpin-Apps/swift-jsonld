import Foundation

/// Locates the [W3C JSON-LD 1.1 test suite](https://github.com/w3c/json-ld-api)
/// on disk.
///
/// The suite is checked in as a git submodule at
/// `Tests/JSONLDTests/json-ld-api`. We resolve the path at compile time
/// using `#filePath`, which means it works for `swift test` runs on the
/// same machine that compiled the tests (the standard local + CI flow).
///
/// If the submodule has not been initialized (`git submodule update --init`),
/// `manifestPath` will return a non-existent path and the smoke tests
/// will surface a clear failure.
enum SuiteLocator {
    /// Absolute path to `Tests/JSONLDTests/json-ld-api/tests/`.
    static let testsDirectory: URL = {
        let thisFile = URL(fileURLWithPath: #filePath)
        // thisFile: .../Tests/JSONLDTests/W3CSuite/SuiteLocator.swift
        return thisFile
            .deletingLastPathComponent()              // W3CSuite
            .deletingLastPathComponent()              // JSONLDTests
            .appendingPathComponent("json-ld-api")
            .appendingPathComponent("tests")
    }()

    /// Absolute path to `Tests/JSONLDTests/json-ld-framing/tests/` —
    /// the separate W3C JSON-LD Framing 1.1 test suite (its own
    /// repo at https://github.com/w3c/json-ld-framing).
    static let framingTestsDirectory: URL = {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("json-ld-framing")
            .appendingPathComponent("tests")
    }()

    /// Path to a named manifest file. Routes `.frame` to the
    /// framing submodule; everything else to the API submodule.
    static func manifestPath(_ name: ManifestName) -> URL {
        switch name {
        case .frame:
            return framingTestsDirectory.appendingPathComponent("frame-manifest.jsonld")
        default:
            return testsDirectory.appendingPathComponent("\(name.rawValue)-manifest.jsonld")
        }
    }

    /// Suite base — selects which submodule fixtures resolve against.
    enum SuiteBase: Sendable {
        case api
        case frame
    }

    /// The named manifests we wire. JSON-LD 1.1 API ships six;
    /// `.frame` lives in the sibling json-ld-framing repo.
    enum ManifestName: String, CaseIterable, Sendable {
        case expand
        case compact
        case flatten
        case fromRdf
        case toRdf
        case remoteDoc = "remote-doc"
        case html
        case frame
    }
}
