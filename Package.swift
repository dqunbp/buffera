// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bufera",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Bufera", targets: ["Bufera"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BuferaCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Bufera", dependencies: ["BuferaCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "BuferaChecks", dependencies: ["BuferaCore"], path: "Tests/BuferaCoreTests")
    ]
)
