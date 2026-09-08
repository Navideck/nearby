// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "nearby",
    platforms: [
        .iOS("13.1"),
        .macOS("10.15")
    ],
    products: [
        .library(name: "nearby", targets: ["nearby"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "nearby",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
