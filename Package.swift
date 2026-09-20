// swift-tools-version: 6.2
// The Mac's hardware senses, read-only by construction: die temperatures
// from the HID event system, fan telemetry and the chip's named parts
// from the SMC, and the public 80-byte SMC codec a privileged daemon can
// compose its own writes on. One product, MachSensors; two consumers, mach
// (what a Mac is and how fast) and chill (fan curves with Apple in charge).
// Floor macOS 13: the senses read any Apple Silicon Mac a buyer meets.
import PackageDescription

let package = Package(
    name: "swift-hw",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MachSensors", targets: ["MachSensors"])
    ],
    targets: [
        .target(
            name: "MachSensors",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
