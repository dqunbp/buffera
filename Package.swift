// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Buffera",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Buffera", targets: ["Buffera"]),
        .executable(name: "BufferaMCP", targets: ["BufferaMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "BufferaLocalization", resources: [.process("Resources")]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "CSQLiteVec", dependencies: ["CSQLite"],
                exclude: ["sqlite-vec.c", "README.md", "LICENSE-MIT", "LICENSE-APACHE"],
                cSettings: [.define("SQLITE_CORE"), .define("SQLITE_VEC_STATIC")]),
        .target(name: "BufferaCore", dependencies: ["CSQLite", "CSQLiteVec", "BufferaLocalization"]),
        .target(name: "BufferaModels", dependencies: ["BufferaLocalization"]),
        .target(name: "BufferaSearch", dependencies: ["BufferaCore", "BufferaModels", "BufferaLocalization"]),
        .target(name: "BufferaChat", dependencies: ["BufferaCore", "BufferaModels", "BufferaSearch", "BufferaLocalization"]),
        .executableTarget(name: "Buffera", dependencies: ["BufferaCore", "BufferaModels", "BufferaSearch", "BufferaChat", "BufferaLocalization"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .target(name: "BufferaMCPKit", dependencies: [
            "BufferaCore", "BufferaSearch", .product(name: "MCP", package: "swift-sdk")
        ]),
        .executableTarget(name: "BufferaMCP", dependencies: ["BufferaMCPKit", "BufferaLocalization"]),
        .executableTarget(name: "BufferaLocalizationChecks", dependencies: ["BufferaLocalization", "BufferaCore"],
                          path: "Tests/LocalizationChecks"),
        .executableTarget(name: "BufferaMCPChecks", dependencies: ["BufferaMCPKit", "BufferaCore", "BufferaSearch", "CSQLite"],
                    path: "Tests/BufferaMCPTests"),
        .executableTarget(name: "BufferaChecks", dependencies: ["BufferaCore"], path: "Tests/BufferaCoreTests"),
        .executableTarget(name: "BufferaModelChecks", dependencies: ["BufferaModels"], path: "Tests/BufferaModelTests"),
        .executableTarget(name: "BufferaEmbeddingRuntimeChecks", dependencies: ["BufferaModels"],
                          path: "Tests/BufferaEmbeddingRuntimeTests"),
        .executableTarget(name: "BufferaSearchChecks", dependencies: ["BufferaCore", "BufferaModels", "BufferaSearch", "BufferaLocalization"],
                          path: "Tests/BufferaSearchTests"),
        .executableTarget(name: "BufferaChatChecks", dependencies: ["BufferaCore", "BufferaModels", "BufferaSearch", "BufferaChat", "CSQLite"],
                          path: "Tests/BufferaChatTests"),
        .executableTarget(name: "BufferaChatRuntimeChecks", dependencies: ["BufferaModels"],
                          path: "Tests/BufferaChatRuntimeTests")
    ]
)
