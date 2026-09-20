// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisDomain", targets: ["JarvisDomain"]),
        .library(name: "JarvisPersistence", targets: ["JarvisPersistence"]),
        .library(name: "JarvisService", targets: ["JarvisService"]),
        .executable(name: "JarvisMenuBar", targets: ["JarvisMenuBar"]),
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
        .target(name: "JarvisLLM", dependencies: ["JarvisDomain"]),
        .target(
            name: "JarvisService",
            dependencies: ["JarvisDomain", "JarvisPersistence", "JarvisPolicy"]
        ),
        .executableTarget(
            name: "JarvisMenuBar",
            dependencies: ["JarvisDomain", "JarvisService", "JarvisPolicy", "JarvisLLM"]
        ),
        .testTarget(name: "JarvisDomainTests", dependencies: ["JarvisDomain"]),
        .testTarget(name: "JarvisLLMTests", dependencies: ["JarvisLLM"]),
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
        .testTarget(
            name: "JarvisMenuBarTests",
            dependencies: ["JarvisMenuBar", "JarvisDomain", "JarvisLLM"]
        ),
        .testTarget(
            name: "JarvisAcceptanceTests",
            dependencies: ["JarvisService", "JarvisDomain", "JarvisPersistence", "JarvisPolicy"]
        ),
    ]
)
