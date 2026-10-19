// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Buffera",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Buffera", targets: ["Buffera"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BufferaCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Buffera", dependencies: ["BufferaCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "BufferaChecks", dependencies: ["BufferaCore"], path: "Tests/BufferaCoreTests")
    ]
)
