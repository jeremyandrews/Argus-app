// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Argus",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "Argus", targets: ["Argus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimonFairbairn/SwiftyMarkdown.git", from: "1.2.4")
    ],
    targets: [
        .target(
            name: "Argus",
            dependencies: ["SwiftyMarkdown"],
            path: "Argus"
        ),
    ]
)
