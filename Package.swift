// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Orbit", targets: ["Jarvis"])],
    targets: [
        .executableTarget(
            name: "Jarvis",
            path: "Sources/Jarvis",
            exclude: ["Info.plist"],
            resources: [.copy("Resources/orbit-aero.png"), .copy("Resources/OrbitAnimations"), .copy("Resources/OrbitModels")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JarvisTests",
            dependencies: ["Jarvis"],
            path: "Tests/JarvisTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
