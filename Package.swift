// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWearablesHealthSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "OpenWearablesHealthSDK", targets: ["OpenWearablesHealthSDK"]),
    ],
    targets: [
        .target(
            name: "OpenWearablesHealthSDK",
            path: "Sources/OpenWearablesHealthSDK",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("HealthKit"),
                .linkedFramework("BackgroundTasks"),
            ]
        ),
        .testTarget(
            name: "OpenWearablesHealthSDKTests",
            dependencies: ["OpenWearablesHealthSDK"]
        ),
    ]
)
