// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TypeFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TypeFlow",
            path: "Sources/TypeFlow",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
