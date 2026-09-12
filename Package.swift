// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "RoutineScout", platforms: [.macOS(.v14)], products: [.executable(name: "RoutineScout", targets: ["RoutineScout"]), .library(name: "ScoutCore", targets: ["ScoutCore"]), .executable(name: "ScoutTests", targets: ["ScoutTests"])], targets: [.systemLibrary(name: "CSQLite"), .target(name: "ScoutCore", dependencies: ["CSQLite"]), .executableTarget(name: "RoutineScout", dependencies: ["ScoutCore"]), .executableTarget(name: "ScoutTests", dependencies: ["ScoutCore"], path: "Tests/ScoutCoreTests")])
