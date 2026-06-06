import Foundation
@testable import JSONLD

/// Read + decode a `.jsonld` fixture file into a `JSONLD.JSON` value.
///
/// JSON-LD fixture files are plain JSON; this helper hides
/// `JSONSerialization` and the conversion to our typed value enum.
enum JSONFixture {
    static func load(_ url: URL) throws -> JSONLD.JSON {
        let data = try Data(contentsOf: url)
        let any = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        return try toJSON(any)
    }

    static func toJSON(_ any: Any) throws -> JSONLD.JSON {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            // CFBoolean → Bool. Otherwise treat as number; if it's
            // integral, use .int, otherwise .double.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d.truncatingRemainder(dividingBy: 1) == 0,
               d >= Double(Int64.min), d <= Double(Int64.max)
            {
                return .int(Int64(d))
            }
            return .double(d)
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] {
            return .array(try arr.map(toJSON))
        }
        if let dict = any as? [String: Any] {
            var out: [String: JSONLD.JSON] = [:]
            for (k, v) in dict { out[k] = try toJSON(v) }
            return .object(out)
        }
        struct UnsupportedType: Error { let valueType: String }
        throw UnsupportedType(valueType: String(describing: type(of: any)))
    }
}

extension TestEntry {
    /// Resolve a fixture path (relative to the manifest's directory)
    /// to an absolute URL on disk.
    ///
    /// Defaults to the JSON-LD API submodule; pass `base: .frame` for
    /// fixtures that live in the JSON-LD Framing submodule.
    func fixtureURL(_ relativePath: String, base: SuiteLocator.SuiteBase = .api) -> URL {
        switch base {
        case .api:
            return SuiteLocator.testsDirectory.appendingPathComponent(relativePath)
        case .frame:
            return SuiteLocator.framingTestsDirectory.appendingPathComponent(relativePath)
        }
    }
}
