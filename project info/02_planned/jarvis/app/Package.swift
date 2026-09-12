// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisDomain", targets: ["JarvisDomain"]),
    ],
    targets: [
        .target(name: "JarvisDomain"),
        .testTarget(name: "JarvisDomainTests", dependencies: ["JarvisDomain"]),
    ]
)
