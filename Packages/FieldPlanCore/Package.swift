// swift-tools-version: 5.9
// FieldPlanCore — platform-independent geometry, measurement, takeoff and export
// engine for FieldPlan. This package intentionally has no UIKit/SwiftUI/RoomPlan
// dependency so the measurement-critical code can be compiled and tested on any
// Swift platform (including Linux CI).
import PackageDescription

let package = Package(
    name: "FieldPlanCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FieldPlanCore", targets: ["FieldPlanCore"])
    ],
    targets: [
        .target(
            name: "FieldPlanCore",
            path: "Sources/FieldPlanCore"
        ),
        .testTarget(
            name: "FieldPlanCoreTests",
            dependencies: ["FieldPlanCore"],
            path: "Tests/FieldPlanCoreTests"
        ),
    ]
)
