import Foundation

extension TestManifest {
    enum LoadError: Error, CustomStringConvertible {
        case manifestMissing(URL)
        case decodingFailed(URL, underlying: any Error)

        var description: String {
            switch self {
            case let .manifestMissing(url):
                return """
                W3C manifest not found at \(url.path).
                Did you run `git submodule update --init`?
                """
            case let .decodingFailed(url, err):
                return "Failed to decode \(url.lastPathComponent): \(err)"
            }
        }
    }

    /// Load and decode a named manifest from the on-disk submodule.
    static func load(_ name: SuiteLocator.ManifestName) throws -> TestManifest {
        let url = SuiteLocator.manifestPath(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.manifestMissing(url)
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(TestManifest.self, from: data)
        } catch {
            throw LoadError.decodingFailed(url, underlying: error)
        }
    }
}
