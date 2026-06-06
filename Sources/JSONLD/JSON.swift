import Foundation

extension JSONLD {
    /// A JSON value as seen by the JSON-LD algorithms.
    ///
    /// Mirrors the JSON data model from [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259):
    /// the seven types are `null`, booleans, numbers (split here into
    /// `int` and `double` because JSON-LD typed values distinguish
    /// `xsd:integer` from `xsd:double`), strings, arrays, and objects.
    ///
    /// Object key order is not preserved — most JSON-LD algorithms sort
    /// keys explicitly during processing, and the canonical N-Quads
    /// output produced by [`RDFCanonize`](https://github.com/Kingpin-Apps/swift-rdf-canonize)
    /// is order-independent. Round-tripping through `JSON` is therefore
    /// not key-order-preserving.
    public indirect enum JSON: Sendable, Hashable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([JSON])
        case object([String: JSON])
    }
}

extension JSONLD.JSON {
    /// `true` if this value is `.null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension JSONLD.JSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONLD.JSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONLD.JSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONLD.JSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONLD.JSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONLD.JSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONLD.JSON...) { self = .array(elements) }
}

extension JSONLD.JSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONLD.JSON)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
