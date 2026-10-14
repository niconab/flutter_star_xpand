// swift-tools-version: 5.9
import PackageDescription

// Used when the host app has Flutter's Swift Package Manager support enabled.
// StarIO10 comes straight from Star's official Swift package (not stored in this repo).
// CocoaPods builds use ../flutter_star_prnt_plus.podspec, which downloads it at pod install.
let package = Package(
    name: "flutter_star_prnt_plus",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "flutter-star-prnt-plus", targets: ["flutter_star_prnt_plus"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/star-micronics/StarXpand-SDK-iOS.git", exact: "2.14.0")
    ],
    targets: [
        .target(
            name: "flutter_star_prnt_plus",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "StarIO10", package: "StarXpand-SDK-iOS"),
            ]
        )
    ]
)
