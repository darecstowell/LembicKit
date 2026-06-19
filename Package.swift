// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LembicKit",
    platforms: [.macOS(.v14)],  // Sonoma floor (macOS version support)
    products: [
        .library(name: "LembicKit", targets: ["LembicKit"]),
        .executable(name: "lembic-cli", targets: ["lembic-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/Madrid.git", from: "0.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "LembicKit",
            dependencies: [
                .product(name: "TypedStream", package: "Madrid"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "lembic-cli",
            dependencies: [
                "LembicKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LembicKitTests",
            dependencies: [
                "LembicKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/LembicKitTests",
            resources: [
                // C3 lands golden .txt fixtures here; included now so Bundle.module
                // exists and the resource-bundle wiring is proven before C3 needs it.
                // `.copy` so files land verbatim (golden transcripts must be byte-exact).
                .copy("Fixtures")
            ]
        ),
    ]
)
