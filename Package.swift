// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AppleCamCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AppleCamCore", targets: ["AppleCamCore"])],
    targets: [
        .target(name: "AppleCamCore", path: "Shared"),
        .target(name: "AppleCamMedia", dependencies: ["AppleCamCore"], path: "AppleCam",
                exclude: ["App/AppleCamApp.swift"], sources: ["Capture", "Transport", "Processing", "App/CameraModel.swift", "App/ExtensionManager.swift"]),
        .testTarget(name: "AppleCamCoreTests", dependencies: ["AppleCamCore"], path: "Tests/Unit"),
        .testTarget(name: "AppleCamMediaTests", dependencies: ["AppleCamMedia"], path: "Tests/Media")
    ],
    swiftLanguageModes: [.v5]
)
