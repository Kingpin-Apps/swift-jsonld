import Testing
import Foundation

/// Verifies the W3C JSON-LD 1.1 test suite is wired up and loadable.
///
/// These tests don't exercise any algorithms — they just prove the
/// submodule is initialized and our manifest decoders match the W3C
/// schema. Per-operation conformance suites (Expand, Compact, Flatten,
/// ToRDF, FromRDF) come online in the phase that implements each
/// algorithm.
@Suite("W3C suite wiring")
struct SuiteSmokeTests {

    @Test("Submodule has been initialized")
    func submoduleInitialized() {
        let path = SuiteLocator.testsDirectory.path
        #expect(
            FileManager.default.fileExists(atPath: path),
            """
            W3C JSON-LD test suite not found at \(path).
            Run `git submodule update --init` and re-run the tests.
            """
        )
    }

    /// Lower bounds on entry counts per manifest as of the pinned
    /// submodule commit. Asserting "at least N" rather than "exactly N"
    /// lets the W3C suite grow without breaking us — if it ever shrinks
    /// past these bounds we want to investigate.
    @Test(
        "Each manifest loads and contains at least the expected number of entries",
        arguments: [
            (SuiteLocator.ManifestName.expand, 380),
            (SuiteLocator.ManifestName.compact, 240),
            (SuiteLocator.ManifestName.flatten, 55),
            (SuiteLocator.ManifestName.fromRdf, 50),
            (SuiteLocator.ManifestName.toRdf, 445),
            (SuiteLocator.ManifestName.remoteDoc, 15),
            (SuiteLocator.ManifestName.html, 45),
            (SuiteLocator.ManifestName.frame, 80),
        ] as [(SuiteLocator.ManifestName, Int)]
    )
    func manifestLoadsWithExpectedCount(
        _ name: SuiteLocator.ManifestName,
        _ minimumEntries: Int
    ) throws {
        let manifest = try TestManifest.load(name)
        #expect(
            manifest.entries.count >= minimumEntries,
            "\(name.rawValue) manifest has \(manifest.entries.count) entries, expected at least \(minimumEntries)"
        )
    }

    @Test("Manifest entries are tagged as Positive or Negative evaluation tests")
    func everyEntryHasEvaluationClass() throws {
        let manifest = try TestManifest.load(.expand)
        for entry in manifest.entries {
            #expect(
                entry.isPositive || entry.isNegative,
                "Entry \(entry.id) (\(entry.name)) is neither Positive nor Negative"
            )
        }
    }

    @Test("Negative entries carry expectErrorCode; Positive entries carry expect")
    func evaluationClassMatchesPayload() throws {
        let manifest = try TestManifest.load(.expand)
        for entry in manifest.entries {
            if entry.isNegative {
                #expect(
                    entry.expectErrorCode != nil,
                    "Negative entry \(entry.id) missing expectErrorCode"
                )
            }
            if entry.isPositive {
                #expect(
                    entry.expect != nil,
                    "Positive entry \(entry.id) missing expect path"
                )
            }
        }
    }
}
