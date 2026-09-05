// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FourthCiv",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FourthCivApp", targets: ["FourthCivApp"]),
        .executable(name: "fourthciv", targets: ["FourthCivCLI"])
    ],
    targets: [
        .target(name: "FourthCivCore"),
        .executableTarget(name: "FourthCivApp", dependencies: ["FourthCivCore"]),
        .executableTarget(name: "FourthCivCLI", dependencies: ["FourthCivCore"]),
        .testTarget(name: "FourthCivCoreTests", dependencies: ["FourthCivCore"])
    ],
    swiftLanguageModes: [.v5]
)
