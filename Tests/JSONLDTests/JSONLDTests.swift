import Testing
@testable import JSONLD

@Suite("JSON value")
struct JSONValueTests {
    @Test("Literal conformances cover every case")
    func literalConformances() {
        let null: JSONLD.JSON = nil
        let bool: JSONLD.JSON = true
        let int: JSONLD.JSON = 42
        let double: JSONLD.JSON = 3.14
        let string: JSONLD.JSON = "hello"
        let array: JSONLD.JSON = [1, "two", false]
        let object: JSONLD.JSON = ["a": 1, "b": "two"]

        #expect(null == .null)
        #expect(bool == .bool(true))
        #expect(int == .int(42))
        #expect(double == .double(3.14))
        #expect(string == .string("hello"))
        #expect(array == .array([.int(1), .string("two"), .bool(false)]))
        #expect(object == .object(["a": .int(1), "b": .string("two")]))
    }

    @Test("isNull discriminates only the null case")
    func isNull() {
        #expect(JSONLD.JSON.null.isNull)
        #expect(!JSONLD.JSON.bool(false).isNull)
        #expect(!JSONLD.JSON.string("").isNull)
        #expect(!JSONLD.JSON.array([]).isNull)
        #expect(!JSONLD.JSON.object([:]).isNull)
    }

    @Test("Int and double are distinct cases")
    func intDoubleDistinct() {
        let int: JSONLD.JSON = .int(1)
        let double: JSONLD.JSON = .double(1.0)
        #expect(int != double)
    }
}

@Suite("ProcessingMode")
struct ProcessingModeTests {
    @Test("Raw values match the spec")
    func rawValues() {
        #expect(JSONLD.ProcessingMode.jsonLd10.rawValue == "json-ld-1.0")
        #expect(JSONLD.ProcessingMode.jsonLd11.rawValue == "json-ld-1.1")
    }
}
