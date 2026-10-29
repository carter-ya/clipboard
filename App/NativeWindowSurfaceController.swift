import AppKit
import ClipboardCore

/// Owns one compositor-backed surface while a window is visible. The
/// hosted SwiftUI content must stay transparent to sample behind it.
@MainActor
final class NativeWindowSurfaceController: NSViewController {
  enum Role {
    case history
    case preferences
  }

  private let hostingController: NSViewController
  private let role: Role
  private let contentSize: NSSize
  private var observingDisplayOptions = false
  private var observingVisibility = false
  private var contentConstraints: [NSLayoutConstraint] = []

  init(hostingController: NSViewController, role: Role, contentSize: NSSize) {
    self.hostingController = hostingController
    self.role = role
    self.contentSize = contentSize
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = contentSize
    addChild(hostingController)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("Unavailable")
  }

  override func loadView() {
    view = NSView(frame: NSRect(origin: .zero, size: contentSize))
  }

  func activate() {
    if !observingVisibility {
      let center = NotificationCenter.default
      center.addObserver(
        self, selector: #selector(applicationWillHide),
        name: NSApplication.willHideNotification, object: NSApp)
      center.addObserver(
        self, selector: #selector(resumeSurface),
        name: NSApplication.didUnhideNotification, object: NSApp)
      if let window = view.window {
        center.addObserver(
          self, selector: #selector(windowDidMiniaturize),
          name: NSWindow.didMiniaturizeNotification, object: window)
        center.addObserver(
          self, selector: #selector(resumeSurface),
          name: NSWindow.didDeminiaturizeNotification, object: window)
      }
      observingVisibility = true
    }
    guard !NSApp.isHidden, view.window?.isMiniaturized != true else { return }
    installVisibleSurface()
  }

  private func installVisibleSurface() {
    if !observingDisplayOptions {
      NSWorkspace.shared.notificationCenter.addObserver(
        self, selector: #selector(displayOptionsDidChange),
        name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
      )
      observingDisplayOptions = true
    }
    if view.subviews.isEmpty { installSurface() }
  }

  func deactivate() {
    NotificationCenter.default.removeObserver(self)
    observingVisibility = false
    suspendSurface()
  }

  @objc private func applicationWillHide() {
    suspendSurface()
  }

  @objc private func windowDidMiniaturize() {
    suspendSurface()
  }

  @objc private func resumeSurface() {
    guard observingVisibility, !NSApp.isHidden,
      let window = view.window, window.isVisible, !window.isMiniaturized
    else { return }
    installVisibleSurface()
  }

  private func suspendSurface() {
    if observingDisplayOptions {
      NSWorkspace.shared.notificationCenter.removeObserver(self)
      observingDisplayOptions = false
    }
    // Detach the native hierarchy and backdrop buffers. Keep the hosting
    // controller's root for temporary hide/minimize so drafts survive.
    NSLayoutConstraint.deactivate(contentConstraints)
    contentConstraints = []
    hostingController.view.removeFromSuperview()
    for surface in view.subviews {
      surface.removeFromSuperview()
    }
  }

  @objc private func displayOptionsDidChange() {
    guard observingDisplayOptions else { return }
    installSurface()
  }

  private func installSurface() {
    NSLayoutConstraint.deactivate(contentConstraints)
    contentConstraints = []
    let content = hostingController.view
    content.removeFromSuperview()
    for surface in view.subviews {
      surface.removeFromSuperview()
    }
    content.frame = view.bounds
    content.autoresizingMask = [.width, .height]
    content.translatesAutoresizingMaskIntoConstraints = true
    // Settings glass fills the titlebar as well as the body. Its hosted
    // form is constrained below the real system toolbar after attachment.
    let canvas: NSView
    if role == .preferences {
      canvas = NSView(frame: view.bounds)
      canvas.addSubview(content)
    } else {
      canvas = content
    }

    let workspace = NSWorkspace.shared
    if workspace.accessibilityDisplayShouldReduceTransparency
      || workspace.accessibilityDisplayShouldIncreaseContrast
    {
      let surface = OpaqueAppearanceSurface(frame: view.bounds)
      if role == .history {
        surface.layer?.cornerRadius = HistoryPanelLayout.cornerRadius
        surface.layer?.masksToBounds = true
      }
      surface.addSubview(canvas)
      attach(surface, content: content, canvas: canvas)
      Log.ui.debug("appearance.surface=opaque accessibilityFallback=true")
      return
    }

    #if compiler(>=6.2)
      if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: view.bounds)
        glass.style = .regular
        glass.cornerRadius = HistoryPanelLayout.cornerRadius
        if role == .history {
          // Keep the proven nonactivating window. Render only the glass
          // 1pt beyond a rounded viewport to hide its contrasting rim.
          // Offset the hosted content back so controls never move/scale.
          let outset: CGFloat = 1
          let viewport = NSView(frame: view.bounds)
          viewport.autoresizingMask = [.width, .height]
          viewport.wantsLayer = true
          viewport.layer?.cornerRadius = HistoryPanelLayout.cornerRadius
          viewport.layer?.cornerCurve = .continuous
          viewport.layer?.masksToBounds = true
          glass.frame = viewport.bounds.insetBy(dx: -outset, dy: -outset)
          glass.autoresizingMask = [.width, .height]
          glass.cornerRadius += outset
          let glassCanvas = NSView(frame: glass.bounds)
          content.frame = view.bounds.offsetBy(dx: outset, dy: outset)
          glassCanvas.addSubview(content)
          glass.contentView = glassCanvas
          viewport.addSubview(glass)
          view.addSubview(viewport)
          Log.ui.debug("appearance.surface=NSGlassEffectView style=regular edgeCrop=1pt")
          return
        }
        // Use the documented contentView slot so native glass remains
        // behind the hosting view, with no opaque SwiftUI plate between.
        glass.contentView = canvas
        attach(glass, content: content, canvas: canvas)
        Log.ui.debug("appearance.surface=NSGlassEffectView style=regular")
        return
      }
    #endif

    let material = NSVisualEffectView(frame: view.bounds)
    material.blendingMode = .behindWindow
    material.material = .popover
    material.state = .active
    if role == .history {
      material.wantsLayer = true
      material.layer?.cornerRadius = HistoryPanelLayout.cornerRadius
      material.layer?.masksToBounds = true
    }
    material.addSubview(canvas)
    attach(material, content: content, canvas: canvas)
    Log.ui.debug("appearance.surface=NSVisualEffectView blending=behindWindow")
  }

  private func attach(_ surface: NSView, content: NSView, canvas: NSView) {
    surface.autoresizingMask = [.width, .height]
    view.addSubview(surface)
    canvas.frame = surface.bounds
    canvas.autoresizingMask = [.width, .height]
    if role == .preferences, let guide = view.window?.contentLayoutGuide {
      content.translatesAutoresizingMaskIntoConstraints = false
      contentConstraints = [
        NSLayoutConstraint(
          item: content, attribute: .leading, relatedBy: .equal,
          toItem: guide, attribute: .leading, multiplier: 1, constant: 0),
        NSLayoutConstraint(
          item: content, attribute: .trailing, relatedBy: .equal,
          toItem: guide, attribute: .trailing, multiplier: 1, constant: 0),
        NSLayoutConstraint(
          item: content, attribute: .top, relatedBy: .equal,
          toItem: guide, attribute: .top, multiplier: 1, constant: 0),
        NSLayoutConstraint(
          item: content, attribute: .bottom, relatedBy: .equal,
          toItem: guide, attribute: .bottom, multiplier: 1, constant: 0),
      ]
      NSLayoutConstraint.activate(contentConstraints)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }
}

/// A CGColor is a resolved snapshot; refresh it when the inherited
/// appearance changes so accessibility fallback follows the theme too.
@MainActor
private final class OpaqueAppearanceSurface: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    updateColor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Unavailable") }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColor()
  }

  private func updateColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
  }
}
