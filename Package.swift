// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoicePloeg",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoicePloeg", targets: ["VoicePloeg"])
    ],
    targets: [
        .executableTarget(
            name: "VoicePloeg",
            path: ".",
            exclude: [
                "Vendor",
                "Scripts",
                ".build",
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
    ]
)
