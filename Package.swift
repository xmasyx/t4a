// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "T4A",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "T4A", targets: ["T4A"]),
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // The grid interface: cells, events, sessions. Knows nothing about any
        // VT engine — this is the hedge that lets the core be swapped.
        .target(name: "TerminalCore"),

        // The GPU renderer. It depends on the grid interface and on Metal —
        // and on no VT library at all, which is the point: it draws cells,
        // and cells are the contract.
        .target(name: "MetalRenderer", dependencies: ["TerminalCore"]),

        // The agent readers. They depend on the grid interface and on
        // nothing else: no VT library, no AppKit view, no vendor SDK. Adding a
        // vendor is a file in here plus a line in AgentRegistry (ISC-31).
        .target(name: "AgentAdapters", dependencies: ["TerminalCore"]),

        // The ONLY target allowed to import SwiftTerm.
        .target(
            name: "SwiftTermBackend",
            dependencies: ["TerminalCore", "MetalRenderer",
                           .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),

        // Quartz entra SOLO qui, e solo per `QLPreviewView` (ISC-176):
        // l'anteprima di un file è una cosa della finestra, e il core, il
        // renderer e gli adattatori restano senza.
        .executableTarget(
            name: "T4A",
            dependencies: ["TerminalCore", "SwiftTermBackend", "AgentAdapters"],
            resources: [.copy("Integration")],
            linkerSettings: [.linkedFramework("Quartz")]
        ),

        .testTarget(name: "AgentAdaptersTests",
                    dependencies: ["AgentAdapters", "TerminalCore"]),
    ]
)
