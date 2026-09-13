// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Handoff",
    // Pinned deliberately. swiftc on this machine defaults to
    // arm64-apple-macosx16.0, which is AHEAD of the installed 15.1 SDK and
    // produces nonsense availability behavior. macOS 15 is also the floor for
    // Synchronization.Atomic, which the SPSC ring buffer needs.
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Handoff",
            path: "Sources/Handoff",
            swiftSettings: [
                // CGEventTap C callbacks and AXUIElementRef are hostile to
                // Swift 6 strict concurrency. Revisit if it stops paying rent.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Phase 0b throwaway: dumps live AX trees so we learn on day one which
        // of the target apps expose anything usable, rather than the night
        // before judging.
        .executableTarget(
            name: "handoff-probe",
            path: "Sources/handoff-probe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
