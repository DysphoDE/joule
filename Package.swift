// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Joule",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "JouleCore",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Joule",
            dependencies: ["JouleCore"],
            linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("UserNotifications")]
        ),
        .executableTarget(name: "JouleChecks", dependencies: ["JouleCore"]),
    ],
    swiftLanguageModes: [.v5]
)
