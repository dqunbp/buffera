// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Buffera",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Buffera", targets: ["Buffera"]),
        .executable(name: "BufferaMCP", targets: ["BufferaMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BufferaCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Buffera", dependencies: ["BufferaCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .target(name: "BufferaMCPKit", dependencies: [
            "BufferaCore", .product(name: "MCP", package: "swift-sdk")
        ]),
        .executableTarget(name: "BufferaMCP", dependencies: ["BufferaMCPKit"]),
        .executableTarget(name: "BufferaMCPChecks", dependencies: ["BufferaMCPKit", "BufferaCore", "CSQLite"],
                    path: "Tests/BufferaMCPTests"),
        .executableTarget(name: "BufferaChecks", dependencies: ["BufferaCore"], path: "Tests/BufferaCoreTests")
    ]
)
