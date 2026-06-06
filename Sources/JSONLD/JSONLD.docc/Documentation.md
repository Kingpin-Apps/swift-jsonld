# ``JSONLD``

Pure-Swift, concurrency-safe implementation of the
[W3C JSON-LD 1.1](https://www.w3.org/TR/json-ld11/) specification.

## Overview

`JSONLD` implements the eight standard JSON-LD operations —
[expand](https://www.w3.org/TR/json-ld11-api/#expansion-algorithms),
[compact](https://www.w3.org/TR/json-ld11-api/#compaction-algorithms),
[flatten](https://www.w3.org/TR/json-ld11-api/#flattening-algorithms),
[frame](https://www.w3.org/TR/json-ld11-framing/), and the
[RDF interchange algorithms](https://www.w3.org/TR/json-ld11-api/#deserialize-json-ld-to-rdf-algorithm)
(`toRDF`, `fromRDF`), plus
[RDFC-1.0 canonicalization](https://www.w3.org/TR/rdf-canon/) wired
through the sibling
[swift-rdf-canonize](https://github.com/Kingpin-Apps/swift-rdf-canonize)
package.

The implementation ships with `Sendable` conformance throughout and
strict concurrency enabled by default. All public APIs are `async` and
throw a single typed error, ``JSONLD/Error``. The library runs against
the W3C JSON-LD 1.1 test suite at 100% conformance (positive and
negative).

## Quickstart

The two operations users reach for most often:

```swift
import JSONLD

let input: JSONLD.JSON = [
    "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
    "name": "Alice",
]

let expanded = try await JSONLD.expand(input)
// → [{ "http://xmlns.com/foaf/0.1/name": [{ "@value": "Alice" }] }]

let canonical = try await JSONLD.canonize(input)
// → "_:c14n0 <http://xmlns.com/foaf/0.1/name> \"Alice\" .\n"
```

`canonize` returns canonical N-Quads suitable for hashing — that's the
operation Cardano
[CIP-100 governance metadata](https://github.com/cardano-foundation/CIPs/tree/master/CIP-0100),
[Verifiable Credentials](https://www.w3.org/TR/vc-data-model/), and
any other signed linked-data document hash over.

## Expand

[Expansion](https://www.w3.org/TR/json-ld11-api/#expansion-algorithms)
resolves every term against its active context, replaces compact IRIs
with absolute ones, and reshapes value objects into the canonical
`{"@value": …, "@type": …}` form.

```swift
let input: JSONLD.JSON = [
    "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
    "name": "Alice",
]

let expanded = try await JSONLD.expand(input)
// → [{ "http://xmlns.com/foaf/0.1/name": [{ "@value": "Alice" }] }]
```

## Compact

[Compaction](https://www.w3.org/TR/json-ld11-api/#compaction-algorithms)
is the reverse of `expand` — it folds absolute IRIs back to terms,
collapses single-value arrays where appropriate, and wraps the result
in the target context.

```swift
let input: JSONLD.JSON = [
    .object([
        "http://xmlns.com/foaf/0.1/name": .array([
            .object(["@value": "Alice"])
        ])
    ])
]
let context: JSONLD.JSON = ["name": "http://xmlns.com/foaf/0.1/name"]

let compacted = try await JSONLD.compact(input, context: context)
// → { "@context": { "name": "http://xmlns.com/foaf/0.1/name" },
//     "name": "Alice" }
```

## Flatten

[Flattening](https://www.w3.org/TR/json-ld11-api/#flattening-algorithms)
hoists every embedded node to the top level keyed by `@id`, replacing
inline references with `{"@id": "…"}` pointers.

```swift
let input: JSONLD.JSON = [
    "@context": ["@vocab": "http://example.org/"],
    "@id": "http://example.org/alice",
    "name": "Alice",
    "knows": .object([
        "@id": "http://example.org/bob",
        "name": "Bob",
    ]),
]
let context: JSONLD.JSON = ["@vocab": "http://example.org/"]

let flat = try await JSONLD.flatten(input, context: context)
// → { "@context": …, "@graph": [
//     { "@id": "http://example.org/alice", "name": "Alice",
//       "knows": { "@id": "http://example.org/bob" } },
//     { "@id": "http://example.org/bob", "name": "Bob" }
//   ] }
```

## Frame

[Framing](https://www.w3.org/TR/json-ld11-framing/) reshapes a document
to match the structure described by a frame — selecting nodes by
`@type`, by predicate, or by example shape, and embedding matched
subjects as nested objects.

```swift
let input: JSONLD.JSON = [
    "@context": ["@vocab": "http://example.org/"],
    "@graph": .array([
        .object(["@id": "ex:alice", "@type": "Person", "name": "Alice"]),
        .object(["@id": "ex:rover", "@type": "Animal", "name": "Rover"]),
    ]),
]
let frame: JSONLD.JSON = [
    "@context": ["@vocab": "http://example.org/"],
    "@type": "Person",
]

let framed = try await JSONLD.frame(input, frame: frame)
// → Only the Person node (Alice) survives in the result.
```

Frame-level defaults — `@embed`, `@explicit`, `@requireAll`,
`@omitDefault`, `@omitGraph` — can be set via the framing fields on
``JSONLD/Options`` or overridden inline in the frame.

## toRDF / fromRDF

`toRDF` converts a JSON-LD document to an RDF
[Dataset](https://www.w3.org/TR/rdf11-concepts/#section-dataset), which
``JSONLD/NQuads`` can serialize to an N-Quads string.

```swift
let input: JSONLD.JSON = [
    "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
    "@id": "http://example.org/alice",
    "name": "Alice",
]

let dataset = try await JSONLD.toRDF(input)
let nquads = JSONLD.NQuads.serialize(dataset)
// → "<http://example.org/alice> <http://xmlns.com/foaf/0.1/name> \"Alice\" .\n"
```

`fromRDF` runs the inverse path:

```swift
let nquads = "<http://example.org/alice> <http://xmlns.com/foaf/0.1/name> \"Alice\" .\n"

let dataset = try JSONLD.NQuads.parseDataset(nquads)
let json = try await JSONLD.fromRDF(dataset)
// → [{ "@id": "http://example.org/alice",
//      "http://xmlns.com/foaf/0.1/name": [{ "@value": "Alice" }] }]
```

Set ``JSONLD/Options/useNativeTypes`` to coerce XSD-typed literals to
native JSON values, or ``JSONLD/Options/useRdfType`` to preserve
`rdf:type` predicates instead of collapsing them into `@type`.

## Canonize

`canonize` is the headline operation for signing and hashing
linked-data documents.

```swift
let a: JSONLD.JSON = [
    "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
    "@id": "http://example.org/alice",
    "name": "Alice",
]
// Same data, written with the absolute IRI instead of the term.
let b: JSONLD.JSON = [
    "@id": "http://example.org/alice",
    "http://xmlns.com/foaf/0.1/name": "Alice",
]

let ca = try await JSONLD.canonize(a)
let cb = try await JSONLD.canonize(b)
assert(ca == cb)  // Semantically equivalent → identical canonical form.
```

Canonicalization is delegated to
[swift-rdf-canonize](https://github.com/Kingpin-Apps/swift-rdf-canonize),
which implements [RDFC-1.0](https://www.w3.org/TR/rdf-canon/) (also
published in earlier drafts as URDNA2015). Blank-node labels are
rewritten to `_:c14n0`, `_:c14n1`, …; quads emit in lexicographic order;
duplicate quads collapse.

## Remote contexts

By default, a string-shaped `@context` reference throws
``JSONLD/Error/loadingRemoteContextFailed(_:)`` — the library does not
fetch from the network unless a loader is supplied. Wire
``URLSessionDocumentLoader`` (or your own ``JSONLDDocumentLoader``)
through ``JSONLD/Options/documentLoader``:

```swift
var options = JSONLD.Options()
options.documentLoader = URLSessionDocumentLoader()

let expanded = try await JSONLD.expand(input, options: options)
```

Custom loaders let you pin contexts to local fixtures, mock network
access in tests, or enforce a content-security policy.

## Conformance

Run the W3C JSON-LD 1.1 test suite with `swift test` — every entry
passes, positive and negative, across all six conformance suites:

| Suite   | Result    |
|---------|-----------|
| Expand  | 273/273 ✓ |
| Compact | 228/228 ✓ |
| Flatten |  54/54  ✓ |
| Frame   |  88/88  ✓ |
| ToRDF   | 335/335 ✓ |
| FromRDF |  42/42  ✓ |
| Negatives | 225/225 ✓ |

The W3C test suites are git submodules under `Tests/JSONLDTests/` —
run `git submodule update --init` after cloning.

## Topics

### Operations

- ``JSONLD/expand(_:options:)``
- ``JSONLD/compact(_:context:options:)``
- ``JSONLD/flatten(_:context:options:)``
- ``JSONLD/frame(_:frame:options:)``
- ``JSONLD/toRDF(_:options:)``
- ``JSONLD/fromRDF(_:options:)``
- ``JSONLD/canonize(_:options:)``

### Options & errors

- ``JSONLD/Options``
- ``JSONLD/Error``
- ``JSONLD/ProcessingMode``

### JSON model

- ``JSONLD/JSON``

### Remote documents

- ``JSONLDDocumentLoader``
- ``URLSessionDocumentLoader``
- ``JSONLD/RemoteDocument``

### Context model

- ``JSONLD/ActiveContext``
- ``JSONLD/TermDefinition``
- ``JSONLD/ContainerKind``
- ``JSONLD/Keyword``

### RDF model

- ``JSONLD/Dataset``
- ``JSONLD/Quad``
- ``JSONLD/Term``
- ``JSONLD/Literal``
- ``JSONLD/NQuads``
