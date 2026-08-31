// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Postmark",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Postmark",
            path: "Postmark",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)