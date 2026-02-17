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
                "Docs",
                "VoicePloeg.xcodeproj",
                "project.yml",
                "App/Info.plist",
                "App/VoicePloeg.entitlements",
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
        )
    ]
)
