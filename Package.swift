// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocaleShift", platforms: [.macOS(.v13)],
    products: [
        .library(name: "LocaleShiftCore", targets: ["LocaleShiftCore"]),
        .executable(name: "LocaleShift", targets: ["LocaleShiftApp"]),
        .executable(name: "LocaleShiftUserAgent", targets: ["LocaleShiftUserAgent"]),
        .executable(name: "LocaleShiftTimezoneService", targets: ["LocaleShiftTimezoneService"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LocaleShiftCore", dependencies: ["CSQLite"], resources: [.process("Resources")]),
        .target(name: "LocaleShiftSystem", dependencies: ["LocaleShiftCore"]),
        .executableTarget(name: "LocaleShiftApp", dependencies: ["LocaleShiftCore", "LocaleShiftSystem"], resources: [.process("Resources")]),
        .executableTarget(name: "LocaleShiftUserAgent", dependencies: ["LocaleShiftCore", "LocaleShiftSystem"]),
        .executableTarget(name: "LocaleShiftTimezoneService", dependencies: ["LocaleShiftCore", "LocaleShiftSystem"]),
        .testTarget(name: "LocaleShiftCoreTests", dependencies: ["LocaleShiftCore"])
    ], swiftLanguageVersions: [.v5]
)
