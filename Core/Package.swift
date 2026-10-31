// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ClipboardCore",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
    .library(name: "DesktopClipboard", targets: ["DesktopClipboard"]),
    .library(name: "DesktopShell", targets: ["DesktopShell"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
  ],
  targets: [
    .systemLibrary(name: "CDBus", pkgConfig: "dbus-1", providers: [.apt(["libdbus-1-dev"])]),
    .target(
      name: "CDesktopShell",
      dependencies: [.target(name: "CDBus", condition: .when(platforms: [.linux]))],
      linkerSettings: [
        .linkedLibrary("user32", .when(platforms: [.windows])),
        .linkedLibrary("shell32", .when(platforms: [.windows])),
        .linkedLibrary("X11", .when(platforms: [.linux])),
      ]
    ),
    .target(name: "DesktopShell", dependencies: ["ClipboardCore", "CDesktopShell"]),
    .target(
      name: "CDesktopClipboard",
      linkerSettings: [
        .linkedLibrary("user32", .when(platforms: [.windows])),
        .linkedLibrary("shell32", .when(platforms: [.windows])),
        .linkedLibrary("X11", .when(platforms: [.linux])),
        .linkedLibrary("Xfixes", .when(platforms: [.linux])),
      ]
    ),
    .target(
      name: "DesktopClipboard",
      dependencies: [
        "ClipboardCore",
        .target(name: "CDesktopClipboard", condition: .when(platforms: [.linux, .windows])),
      ]
    ),
    .target(
      name: "ClipboardCore",
      dependencies: [
        .product(
          name: "KeyboardShortcuts", package: "KeyboardShortcuts",
          condition: .when(platforms: [.macOS])
        ),
        .product(
          name: "Crypto", package: "swift-crypto",
          condition: .when(platforms: [.linux, .windows])
        ),
      ]
    ),
    .executableTarget(
      name: "scenario-runner",
      dependencies: [
        "ClipboardCore",
        .target(name: "DesktopClipboard", condition: .when(platforms: [.linux, .windows])),
        .target(name: "DesktopShell", condition: .when(platforms: [.linux, .windows])),
      ]
    ),
    .testTarget(
      name: "ClipboardCoreTests",
      dependencies: [
        "ClipboardCore",
        .target(name: "DesktopClipboard", condition: .when(platforms: [.linux, .windows])),
      ]
    ),
  ]
)
