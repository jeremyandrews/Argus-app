// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Argus",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "Argus", targets: ["Argus"]),
    ],
    targets: [
        .target(
            name: "Argus",
            path: "Argus"
        ),
    ]
)
