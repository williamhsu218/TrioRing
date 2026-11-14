// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrioRing",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TrioRing", targets: ["RingABar"]),
        .executable(name: "TrioRingPowerHelper", targets: ["TrioRingPowerHelper"]),
        .executable(name: "TrioRingLauncher", targets: ["Launcher"])
    ],
    targets: [
        .target(name: "PowerUIBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .target(name: "PowerModeServiceProtocol"),
        .executableTarget(name: "TrioRingPowerHelper", dependencies: ["PowerModeServiceProtocol"]),
        .executableTarget(name: "RingABar", dependencies: ["PowerUIBridge", "PowerModeServiceProtocol"]),
        .executableTarget(name: "Launcher"),
        .testTarget(name: "RingABarTests", dependencies: ["RingABar"])
    ]
)
