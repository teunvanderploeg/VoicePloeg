// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoicePloeg",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoicePloeg", targets: ["VoicePloeg"])
    ],
    dependencies: [.package(path: "../PloegKit")],
    targets: [
        .executableTarget(
            name: "VoicePloeg",
            dependencies: [.product(name: "PloegKit", package: "PloegKit")],
            path: ".",
            exclude: [
                "Vendor",
                "Scripts",
                ".build",
                "build",
                "README.md",
                ".gitignore",
                "voiceploeg.png",
                "Docs",
                "Tests",
                "VoicePloeg.xcodeproj",
                "project.yml",
                "AGENTS.md",
                "App/Info.plist",
                "App/VoicePloeg.entitlements",
                "App/Assets.xcassets",
                "Core/STT/WhisperBridge.mm"
            ],
            sources: [
                "App",
                "Core",
                "UI"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "VoicePloegTests",
            dependencies: ["VoicePloeg"],
            path: "Tests/VoicePloegTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
