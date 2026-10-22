// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftUILayoutInspector",
    platforms: [
        .iOS(.v17),
        // The inspector itself is iOS-only. On macOS the API compiles and does nothing,
        // so multiplatform code can keep its `.layoutInspector()` calls.
        .macOS(.v14),
    ],
    products: [
        .library(name: "LayoutInspector", targets: ["LayoutInspector"]),
    ],
    traits: [
        .trait(
            name: "LayoutInspectorEngine",
            description: """
            Compiles the inspector in. Without it every API is still available but does nothing, \
            and the binary contains no references to private SwiftUI / AttributeGraph API. \
            Disable with `.package(url: …, from: …, traits: [])`.
            """
        ),
        .default(enabledTraits: ["LayoutInspectorEngine"]),
    ],
    targets: [
        .target(
            name: "LayoutInspector",
            dependencies: [
                .target(name: "LayoutInspectorAttributeGraph", condition: .when(traits: ["LayoutInspectorEngine"])),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(name: "LayoutInspectorAttributeGraph"),
        .testTarget(
            name: "LayoutInspectorTests",
            dependencies: ["LayoutInspector"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
