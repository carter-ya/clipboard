// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ClipboardCore",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "ClipboardCore", targets: ["ClipboardCore"])
  ],
  dependencies: [
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
  ],
  targets: [
    .target(
      name: "ClipboardCore",
      dependencies: [
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
      ]
    ),
    .executableTarget(
      name: "scenario-runner",
      dependencies: ["ClipboardCore"]
    ),
    .testTarget(
      name: "ClipboardCoreTests",
      dependencies: ["ClipboardCore"]
    ),
  ]
)
