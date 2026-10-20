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
        .target(name: "CSQLiteVec", dependencies: ["CSQLite"],
                exclude: ["sqlite-vec.c", "README.md", "LICENSE-MIT", "LICENSE-APACHE"],
                cSettings: [.define("SQLITE_CORE"), .define("SQLITE_VEC_STATIC")]),
        .target(name: "BufferaCore", dependencies: ["CSQLite", "CSQLiteVec"]),
        .target(name: "BufferaModels"),
        .target(name: "BufferaSearch", dependencies: ["BufferaCore", "BufferaModels"]),
        .target(name: "BufferaChat", dependencies: ["BufferaCore", "BufferaModels", "BufferaSearch"]),
        .executableTarget(name: "Buffera", dependencies: ["BufferaCore", "BufferaModels", "BufferaSearch", "BufferaChat"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .target(name: "BufferaMCPKit", dependencies: [
            "BufferaCore", "BufferaSearch", .product(name: "MCP", package: "swift-sdk")
        ]),
        .executableTarget(name: "BufferaMCP", dependencies: ["BufferaMCPKit"]),
        .executableTarget(name: "BufferaMCPChecks", dependencies: ["BufferaMCPKit", "BufferaCore", "BufferaSearch", "CSQLite"],
                    path: "Tests/BufferaMCPTests"),
        .executableTarget(name: "BufferaChecks", dependencies: ["BufferaCore"], path: "Tests/BufferaCoreTests"),
        .executableTarget(name: "BufferaModelChecks", dependencies: ["BufferaModels"], path: "Tests/BufferaModelTests"),
        .executableTarget(name: "BufferaEmbeddingRuntimeChecks", dependencies: ["BufferaModels"],
                          path: "Tests/BufferaEmbeddingRuntimeTests"),
        .executableTarget(name: "BufferaSearchChecks", dependencies: ["BufferaCore", "BufferaModels", "BufferaSearch"],
                          path: "Tests/BufferaSearchTests"),
        .executableTarget(name: "BufferaChatChecks", dependencies: ["BufferaCore", "BufferaModels", "BufferaSearch", "BufferaChat"],
                          path: "Tests/BufferaChatTests"),
        .executableTarget(name: "BufferaChatRuntimeChecks", dependencies: ["BufferaModels"],
                          path: "Tests/BufferaChatRuntimeTests")
    ]
)
