// swift-tools-version: 5.9
import PackageDescription

// The portable half of Softspoke, as a package that builds anywhere Swift runs.
//
// The macOS app is still built by `build.sh` with `xcrun swiftc`, because a
// SwiftUI `.app` bundle needs an Info.plist and a code signature that SwiftPM
// does not produce. That build compiles these same files directly, so nothing
// here is a second copy.
//
// What this manifest adds is a way to compile and test `Sources/Core` without a
// Mac — which is how Windows support gets verified before a Windows UI exists,
// and what makes the code navigable in an editor that expects a package.
let package = Package(
    name: "Softspoke",
    // Only constrains Apple platforms; Windows and Linux builds ignore it. The
    // app itself needs macOS 26, but the portable core needs far less, and
    // keeping this low is what lets CI check the core on older runners.
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SoftspokeCore", targets: ["SoftspokeCore"]),
    ],
    targets: [
        .target(name: "SoftspokeCore", path: "Sources/Core"),
        .testTarget(name: "SoftspokeCoreTests", dependencies: ["SoftspokeCore"], path: "Tests/Core"),
    ]
)
