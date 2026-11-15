// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "MightySPulse",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [.library(name: "MightySPulse", targets: ["MightySPulse"])],
    targets: [
        .target(name: "PulseCompression", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "MightySPulse", dependencies: ["PulseCompression"],
                resources: [.process("Resources/PrivacyInfo.xcprivacy")]),
        .testTarget(name: "MightySPulseTests", dependencies: ["MightySPulse", "PulseCompression"],
                    resources: [.copy("Fixtures")])
    ]
)
