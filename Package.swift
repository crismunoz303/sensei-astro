// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SenseiAstroCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SenseiAstroCore", targets: ["SenseiAstroCore"])
    ],
    targets: [
        .target(
            name: "SenseiAstroCore",
            path: "SenseiAstro/Shared"
        ),
        .testTarget(
            name: "SenseiAstroCoreTests",
            dependencies: ["SenseiAstroCore"],
            path: "SenseiAstroTests"
        )
    ]
)
