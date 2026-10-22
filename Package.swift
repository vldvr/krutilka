// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Krutilka",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Krutilka",
            dependencies: ["KrutilkaKit"]
        ),
        .target(
            name: "KrutilkaKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Checks that run without Xcode: `swift run krutilka-checks`.
        .executableTarget(
            name: "krutilka-checks",
            dependencies: ["KrutilkaKit"],
            path: "Checks"
        ),
    ]
)
