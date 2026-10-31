// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "ClipboardDesktop",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "ClipboardDesktop", targets: ["ClipboardDesktop"])],
  dependencies: [
    .package(path: "../Core"),
    .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.10.0"),
    // Match the compiler used by both validation runners and SwiftCrossUI's current syntax dependencies.
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.1"),
  ],
  targets: [
    .executableTarget(
      name: "ClipboardDesktop",
      dependencies: [
        .product(name: "ClipboardCore", package: "Core"),
        .product(
          name: "DesktopClipboard", package: "Core",
          condition: .when(platforms: [.linux, .windows])),
        .product(name: "DesktopShell", package: "Core"),
        .product(name: "DesktopServices", package: "Core"),
        .product(name: "Gtk", package: "swift-cross-ui"),
        .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
        .product(name: "GtkBackend", package: "swift-cross-ui"),
      ],
      linkerSettings: [
        .unsafeFlags(
          [
            "-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup",
            // GTK's native chooser also creates threads using the executable's
            // default reserve. Match the 8 MiB stack used by the Linux runner;
            // leave the initial committed memory at the linker default.
            "-Xlinker", "/STACK:8388608",
          ],
          .when(platforms: [.windows]))
      ]
    )
  ]
)
