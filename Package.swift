// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "filo",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "FiloCore", targets: ["FiloCore"]),
        .executable(name: "filo", targets: ["FiloApp"]),
        .executable(name: "filo-lab", targets: ["FiloLab"])
    ],
    targets: [
        .target(name: "FiloPCM", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "FiloCore", dependencies: ["FiloPCM"]),
        .executableTarget(name: "FiloApp", dependencies: ["FiloCore"]),
        .executableTarget(name: "FiloLab", dependencies: ["FiloCore"]),
        .testTarget(name: "FiloCoreTests", dependencies: ["FiloCore", "FiloPCM"])
    ]
)
