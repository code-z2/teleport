// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeleportCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "TeleportCore", targets: ["TeleportCore"])],
    targets: [
        .target(name: "TeleportCore"),
        .testTarget(name: "TeleportCoreTests", dependencies: ["TeleportCore"]),
    ]
)
