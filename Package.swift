// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Orbit", platforms: [.macOS(.v15)],
  products: [.executable(name: "Orbit", targets: ["OrbitDesktop"])],
  targets: [
    .target(name: "OrbitCore"),
    .executableTarget(
      name: "OrbitDesktop", dependencies: ["OrbitCore"], resources: [.copy("Resources")]),
    .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"]),
    .testTarget(name: "OrbitDesktopTests", dependencies: ["OrbitDesktop", "OrbitCore"]),
  ]
)
