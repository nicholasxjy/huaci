// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Huaci",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Huaci", targets: ["Huaci"]),
    ],
    targets: [
        .target(
            name: "HuaciCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Huaci",
            dependencies: ["HuaciCore"]
        ),
        .testTarget(
            name: "HuaciCoreTests",
            dependencies: ["HuaciCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
