// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TypeFlow",
    // Bumped to macOS 26 for the FoundationModels framework (on-device LLM
    // powering inline ghost-text completion). Drops pre-Tahoe support — the
    // owner is on 26.4; isolate into a separate target later if wider
    // distribution is ever needed.
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "TypeFlow",
            path: "Sources/TypeFlow",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("FoundationModels"),
            ]
        )
    ]
)
