// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisDomain", targets: ["JarvisDomain"]),
        .library(name: "JarvisPersistence", targets: ["JarvisPersistence"]),
        .library(name: "JarvisService", targets: ["JarvisService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.8.0"),
    ],
    targets: [
        .target(name: "JarvisDomain"),
        .target(name: "JarvisPolicy", dependencies: ["JarvisDomain"]),
        .target(
            name: "JarvisPersistence",
            dependencies: [
                "JarvisDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "JarvisService",
            dependencies: ["JarvisDomain", "JarvisPersistence", "JarvisPolicy"]
        ),
        .testTarget(name: "JarvisDomainTests", dependencies: ["JarvisDomain"]),
        .testTarget(name: "JarvisPolicyTests", dependencies: ["JarvisPolicy", "JarvisDomain"]),
        .testTarget(
            name: "JarvisPersistenceTests",
            dependencies: [
                "JarvisPersistence",
                "JarvisDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "JarvisServiceTests",
            dependencies: ["JarvisService", "JarvisDomain", "JarvisPersistence", "JarvisPolicy"]
        ),
    ]
)
