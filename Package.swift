// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Teum", platforms: [.macOS(.v14)], targets: [
    .target(name: "QuotaModel", path: "Vendor/QuotaModel", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "QuotaRelay", dependencies: ["QuotaModel"], path: "Vendor/QuotaRelay", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "QuotaCore", dependencies: ["QuotaModel", "QuotaRelay"], path: "Vendor/QuotaCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "Teum", dependencies: ["QuotaCore", "QuotaModel"], exclude:["Resources"], swiftSettings: [.swiftLanguageMode(.v5)])
])
