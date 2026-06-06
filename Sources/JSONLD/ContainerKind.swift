extension JSONLD {
    /// Values that may appear in a term's `@container` mapping.
    ///
    /// See [JSON-LD 1.1 §4.6 "Container Type Mapping"](https://www.w3.org/TR/json-ld11/#container-type-mapping).
    /// A term's container mapping is a *set* of these (e.g. `@set` + `@id`)
    /// — JSON-LD permits combining most of them in well-defined ways.
    public enum ContainerKind: String, Sendable, Hashable, CaseIterable {
        case list = "@list"
        case set = "@set"
        case index = "@index"
        case language = "@language"
        case id = "@id"
        case type = "@type"
        case graph = "@graph"
    }
}
