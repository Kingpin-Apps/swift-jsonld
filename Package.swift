// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "JSONLD",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "JSONLD",
            targets: ["JSONLD"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Kingpin-Apps/swift-rdf-canonize.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "JSONLD",
            dependencies: [
                .product(name: "RDFCanonize", package: "swift-rdf-canonize"),
            ]
        ),
        .testTarget(
            name: "JSONLDTests",
            dependencies: ["JSONLD"],
            // The W3C test suites are git submodules. We read fixtures from
            // disk at runtime (via #filePath) rather than bundling them as
            // resources, so SPM should ignore the entire directories.
            exclude: ["json-ld-api", "json-ld-framing"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
