// swift-tools-version: 6.2
// Major Tom: a disk cleaner for developer Macs. MIT licensed, see LICENSE.
import PackageDescription

let package = Package(
    name: "MajorTom",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MajorTomCore", targets: ["MajorTomCore"]),
        .executable(name: "majortom", targets: ["majortom"]),
        .executable(name: "MajorTomApp", targets: ["MajorTomApp"]),
    ],
    targets: [
        .target(name: "MajorTomCore"),
        .target(name: "MajorTomCLI", dependencies: ["MajorTomCore"]),
        .executableTarget(name: "majortom", dependencies: ["MajorTomCore", "MajorTomCLI"]),
        .target(name: "GroundControl", dependencies: ["MajorTomCore"]),
        .executableTarget(name: "MajorTomApp", dependencies: ["MajorTomCore", "GroundControl"]),
        .testTarget(name: "MajorTomCoreTests", dependencies: ["MajorTomCore"]),
        .testTarget(name: "GroundControlTests", dependencies: ["GroundControl", "MajorTomCore"]),
        .testTarget(name: "MajorTomCLITests", dependencies: ["MajorTomCLI", "MajorTomCore"]),
    ],
    swiftLanguageModes: [.v6]
)
