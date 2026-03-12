// swift-tools-version: 6.0
import PackageDescription
import Foundation

let vendorXCFrameworkPath = "Vendor/FFmpeg/FFmpeg.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let vendorXCFrameworkAbsolutePath = packageRoot.appendingPathComponent(vendorXCFrameworkPath).path
let hasVendorFFmpeg = FileManager.default.fileExists(atPath: vendorXCFrameworkAbsolutePath)

var decodeDependencies: [Target.Dependency] = ["PlayerCore", "FFmpegBridge"]
if hasVendorFFmpeg {
    decodeDependencies.append("FFmpegBinary")
}

var ffmpegBridgeDependencies: [Target.Dependency] = []
if hasVendorFFmpeg {
    ffmpegBridgeDependencies.append("FFmpegBinary")
}

var targets: [Target] = [
    .target(
        name: "PlayerCore"
    ),
    .target(
        name: "Input",
        dependencies: ["PlayerCore"]
    ),
    .target(
        name: "Demux",
        dependencies: ["PlayerCore", "Input", "FFmpegBridge"]
    ),
    .target(
        name: "Decode",
        dependencies: decodeDependencies
    ),
    .target(
        name: "Render",
        dependencies: ["PlayerCore"]
    ),
    .target(
        name: "Audio",
        dependencies: ["PlayerCore"]
    ),
    .target(
        name: "PiP",
        dependencies: ["PlayerCore", "Render"]
    ),
    .target(
        name: "FFmpegBridge",
        dependencies: ffmpegBridgeDependencies,
        path: "Sources/Adapters/FFmpegBridge",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedLibrary("z"),
            .linkedLibrary("bz2"),
            .linkedLibrary("iconv")
        ]
    ),
    .target(
        name: "SVP",
        dependencies: ["PlayerCore", "Input", "Demux", "Decode", "Render", "Audio", "PiP", "FFmpegBridge"]
    ),
    .executableTarget(
        name: "AVSmoke",
        dependencies: ["SVP", "Input", "PlayerCore"]
    )
]

if hasVendorFFmpeg {
    targets.append(
        .binaryTarget(
            name: "FFmpegBinary",
            path: vendorXCFrameworkPath
        )
    )
}

let package = Package(
    name: "SVP",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SVP", targets: ["SVP"]),
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
        .library(name: "Input", targets: ["Input"]),
        .library(name: "Demux", targets: ["Demux"]),
        .library(name: "Decode", targets: ["Decode"]),
        .library(name: "Render", targets: ["Render"]),
        .library(name: "Audio", targets: ["Audio"]),
        .library(name: "PiP", targets: ["PiP"]),
        .executable(name: "AVSmoke", targets: ["AVSmoke"])
    ],
    targets: targets
)
