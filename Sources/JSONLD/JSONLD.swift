/// Swift implementation of [JSON-LD 1.1](https://www.w3.org/TR/json-ld11/).
///
/// `JSONLD` is the public namespace for the package. Use the nested types
/// and static functions directly — there is no instance to construct.
///
/// All eight spec operations are implemented and run against the W3C
/// JSON-LD 1.1 test suite at 100% conformance (positive + negative):
///
/// - ``JSONLD/expand(_:options:)``
/// - ``JSONLD/compact(_:context:options:)``
/// - ``JSONLD/flatten(_:context:options:)``
/// - ``JSONLD/frame(_:frame:options:)``
/// - ``JSONLD/toRDF(_:options:)`` / ``JSONLD/fromRDF(_:options:)``
/// - ``JSONLD/canonize(_:options:)``
public enum JSONLD {}
