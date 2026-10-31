// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ClipboardCore",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
    .library(name: "DesktopClipboard", targets: ["DesktopClipboard"]),
    .library(name: "DesktopShell", targets: ["DesktopShell"]),
    .library(name: "DesktopServices", targets: ["DesktopServices"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
    // Pin upstream Windows support rather than relying on a moving branch.
    .package(
      url: "https://github.com/weichsel/ZIPFoundation.git",
      revision: "e7a17d57c583067eaa6659cd6d9521265b7664e9"),
  ],
  targets: [
    .systemLibrary(
      name: "CLibSecret", pkgConfig: "libsecret-1", providers: [.apt(["libsecret-1-dev"])]),
    .systemLibrary(
      name: "CTesseract", pkgConfig: "tesseract",
      providers: [.apt(["libtesseract-dev", "libleptonica-dev"])]),
    .target(
      name: "CDesktopServices",
      dependencies: [
        .target(name: "CLibSecret", condition: .when(platforms: [.linux])),
        .target(name: "CTesseract", condition: .when(platforms: [.linux])),
      ],
      linkerSettings: [
        .linkedLibrary("advapi32", .when(platforms: [.windows])),
        .linkedLibrary("lept", .when(platforms: [.linux])),
      ]),
    .target(
      name: "DesktopServices", dependencies: ["ClipboardCore", "CDesktopServices"],
      resources: [.copy("Resources/WindowsOCR.ps1")]),
    .systemLibrary(
      name: "CWayland", pkgConfig: "wayland-client", providers: [.apt(["libwayland-dev"])]),
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
      dependencies: [.target(name: "CWayland", condition: .when(platforms: [.linux]))],
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
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        .product(
          name: "KeyboardShortcuts", package: "KeyboardShortcuts",
          condition: .when(platforms: [.macOS])
        ),
        .product(
          name: "Crypto", package: "swift-crypto",
          condition: .when(platforms: [.linux, .windows])
        ),
      ],
      resources: [.copy("Resources/DesktopStrings.json")]
    ),
    .target(
      name: "CPlatformScenarioFixtures",
      linkerSettings: [.linkedLibrary("user32", .when(platforms: [.windows]))]),
    .executableTarget(
      name: "scenario-runner",
      dependencies: [
        "ClipboardCore",
        .target(name: "CPlatformScenarioFixtures", condition: .when(platforms: [.windows])),
        .target(name: "DesktopClipboard", condition: .when(platforms: [.linux, .windows])),
        .target(name: "DesktopShell", condition: .when(platforms: [.linux, .windows])),
        .target(name: "DesktopServices", condition: .when(platforms: [.linux, .windows])),
      ]
    ),
    .testTarget(
      name: "ClipboardCoreTests",
      dependencies: [
        "ClipboardCore",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        .target(name: "DesktopClipboard", condition: .when(platforms: [.linux, .windows])),
      ]
    ),
  ]
)
