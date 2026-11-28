// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrioRing",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TrioRing", targets: ["RingABar"]),
        .executable(name: "TrioRingPowerHelper", targets: ["TrioRingPowerHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
    ],
    targets: [
        .target(name: "PowerUIBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .target(name: "PowerModeServiceProtocol"),
        .executableTarget(name: "TrioRingPowerHelper", dependencies: ["PowerModeServiceProtocol"]),
        .executableTarget(
            name: "RingABar",
            dependencies: ["PowerUIBridge", "PowerModeServiceProtocol", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "RingABarTests", dependencies: ["RingABar"])
    ]
)
