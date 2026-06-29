// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "system-health-hook",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "system-health-context", targets: ["SystemHealthContext"])
    ],
    targets: [
        .executableTarget(
            name: "SystemHealthContext",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
