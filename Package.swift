// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FourthCiv",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FourthCivApp", targets: ["FourthCivApp"]),
        .executable(name: "fourthciv", targets: ["FourthCivCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "FourthCivCore"),
        .executableTarget(name: "FourthCivApp", dependencies: ["FourthCivCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "FourthCivCLI", dependencies: ["FourthCivCore"]),
        .testTarget(name: "FourthCivCoreTests", dependencies: ["FourthCivCore"])
    ],
    swiftLanguageModes: [.v5]
)
