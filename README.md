# swift-jsonld

A pure-Swift, concurrency-safe implementation of the
[W3C JSON-LD 1.1](https://www.w3.org/TR/json-ld11/) specification.

Sendable throughout, strict concurrency enabled by default. Runs
against the W3C JSON-LD 1.1 test suite at **100% conformance** —
positive and negative — across all six suites (expand, compact,
flatten, frame, toRDF, fromRDF).

## Features

- **`JSONLD.expand`** — expansion algorithm
- **`JSONLD.compact`** — compaction algorithm
- **`JSONLD.flatten`** — flattening algorithm
- **`JSONLD.frame`** — framing algorithm ([JSON-LD Framing 1.1](https://www.w3.org/TR/json-ld11-framing/))
- **`JSONLD.toRDF` / `JSONLD.fromRDF`** — RDF dataset conversion
- **`JSONLD.canonize`** — RDFC-1.0 canonicalization, delegating to the
  sibling package
  [swift-rdf-canonize](https://github.com/Kingpin-Apps/swift-rdf-canonize)
- **`JSONLDDocumentLoader`** — pluggable remote-document loader
  (URLSession-backed default, with an actor-isolated LRU cache)

## Platforms

Pure Swift, Foundation only, no C dependencies. Builds anywhere Swift 6
runs:

- iOS 14+, macOS 13+, watchOS 9+, tvOS 14+, visionOS 1+
- Linux (Swift 6.0+)

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Kingpin-Apps/swift-jsonld.git", from: "0.1.0"),
],
```

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "JSONLD", package: "swift-jsonld"),
    ]
),
```

## Usage

Every code example below has a matching test in
[`Tests/JSONLDTests/Examples/DocumentationExamples.swift`](Tests/JSONLDTests/Examples/DocumentationExamples.swift)
— copy any snippet into your own code and it will run.

### Expand

```swift
import JSONLD

let input: JSONLD.JSON = [
    "@context": ["name": "http://xmlns.com/foaf/0.1/name"],
    "name": "Alice",
]

let expanded = try await JSONLD.expand(input)
// → [{ "http://xmlns.com/foaf/0.1/name": [{ "@value": "Alice" }] }]
```

### Compact

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

### Canonize (hash-ready N-Quads)

The canonicalize-then-hash pattern used by
[CIP-100 governance metadata](https://github.com/cardano-foundation/CIPs/tree/master/CIP-0100)
and [Verifiable Credentials](https://www.w3.org/TR/vc-data-model/):

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

### Remote contexts

By default a string-shaped `@context` reference throws
`loadingRemoteContextFailed` — the library does not touch the network
unless a loader is supplied:

```swift
var options = JSONLD.Options()
options.documentLoader = URLSessionDocumentLoader()

let expanded = try await JSONLD.expand(input, options: options)
```

The full DocC catalog covers all eight operations with worked examples;
see [Sources/JSONLD/JSONLD.docc/Documentation.md](Sources/JSONLD/JSONLD.docc/Documentation.md).
Xcode renders it via Product → Build Documentation, and the Swift
Package Index builds it remotely from
[`.spi.yml`](.spi.yml).

## Conformance

```
$ swift test
```

| Suite       | Result      |
|-------------|-------------|
| Expand      | 273/273 ✓   |
| Compact     | 228/228 ✓   |
| Flatten     |  54/54  ✓   |
| Frame       |  88/88  ✓   |
| ToRDF       | 335/335 ✓   |
| FromRDF     |  42/42  ✓   |
| Negatives   | 225/225 ✓   |
| **Total**   | **1245/1245** |

The W3C test suites are git submodules under `Tests/JSONLDTests/` —
run `git submodule update --init` after cloning.

## License

MIT. See [LICENSE](LICENSE).
