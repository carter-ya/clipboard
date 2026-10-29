import AppKit
import QuartzCore

/// A small, compositor-driven accent that stays alive across preference tabs.
@MainActor
final class AISparkleToolbarButton: NSButton {
  var allowsAnimation = false {
    didSet {
      if allowsAnimation, !NSApp.isHidden,
        window?.isVisible == true, window?.isMiniaturized == false
      {
        suspended = false
      }
      updateAnimation()
    }
  }

  private let mainStar = CAShapeLayer()
  private let sparkles = (0..<7).map { _ in CAShapeLayer() }
  private let reduceMotion: @MainActor () -> Bool
  private var observingDisplayOptions = false
  private var clickMonitor: Any?
  private var trackingToolbarClick = false
  private var suspended = false
  private(set) var isAnimating = false

  init(
    reduceMotion: @escaping @MainActor () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
  ) {
    self.reduceMotion = reduceMotion
    super.init(frame: NSRect(x: 0, y: 0, width: 52, height: 32))
    title = ""
    isBordered = false
    imagePosition = .imageOnly
    setButtonType(.momentaryChange)
    setAccessibilityLabel(String(localized: "AI"))
    identifier = NSUserInterfaceItemIdentifier("preferences-ai")
    wantsLayer = true
    mainStar.name = "ai.primary"
    mainStar.shadowOpacity = 0.25
    mainStar.shadowRadius = 2
    mainStar.shadowOffset = .zero
    layer?.addSublayer(mainStar)
    for (index, sparkle) in sparkles.enumerated() {
      sparkle.opacity = index < 2 ? 0.85 : 0
      layer?.addSublayer(sparkle)
    }
    needsLayout = true
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Unavailable") }

  override var intrinsicContentSize: NSSize { NSSize(width: 52, height: 32) }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let flipped = layer?.isGeometryFlipped ?? isFlipped
    func location(x: CGFloat, y: CGFloat) -> NSPoint {
      NSPoint(x: x, y: flipped ? bounds.height - y : y)
    }
    mainStar.bounds = NSRect(x: 0, y: 0, width: 24, height: 24)
    mainStar.position = location(x: bounds.midX, y: bounds.midY)
    mainStar.path = Self.starPath(size: 24)
    mainStar.shadowPath = mainStar.path
    mainStar.contentsScale = window?.backingScaleFactor ?? 2
    let positions: [(CGFloat, CGFloat, CGFloat)] = [
      (11.5, 24, 11), (23, 28, 5.5), (5, 13, 7), (44, 25, 7),
      (45, 9, 6), (5.5, 25, 5.5), (14, 5, 5.5),
    ]
    for (sparkle, position) in zip(sparkles, positions) {
      let (x, y, size) = position
      sparkle.bounds = NSRect(x: 0, y: 0, width: size, height: size)
      sparkle.position = location(x: x, y: y)
      sparkle.path = Self.starPath(size: size)
      sparkle.contentsScale = window?.backingScaleFactor ?? 2
    }
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    stopAnimation()
    stopObservingDisplayOptions()
    stopMonitoringClicks()
    suspended = false
    guard let window else { return }
    let center = NotificationCenter.default
    for name in [
      NSWindow.didBecomeKeyNotification, NSWindow.didExposeNotification,
      NSWindow.didChangeOcclusionStateNotification,
    ] {
      center.addObserver(
        self, selector: #selector(visibilityChanged), name: name, object: window)
    }
    for name in [NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification] {
      center.addObserver(
        self, selector: #selector(suspendAnimation), name: name, object: window)
    }
    center.addObserver(
      self, selector: #selector(resumeAnimation),
      name: NSWindow.didDeminiaturizeNotification, object: window)
    center.addObserver(
      self, selector: #selector(suspendAnimation),
      name: NSApplication.willHideNotification, object: NSApp)
    center.addObserver(
      self, selector: #selector(resumeAnimation),
      name: NSApplication.didUnhideNotification, object: NSApp)
    center.addObserver(
      self, selector: #selector(cancelToolbarClick),
      name: NSWindow.didResignKeyNotification, object: window)
    center.addObserver(
      self, selector: #selector(cancelToolbarClick),
      name: NSApplication.didResignActiveNotification, object: NSApp)
    updateAnimation()
  }

  override func viewDidHide() {
    super.viewDidHide()
    updateAnimation()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    updateAnimation()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }

  @objc private func visibilityChanged() { updateAnimation() }

  @objc private func suspendAnimation() {
    suspended = true
    updateAnimation()
  }

  @objc private func resumeAnimation() {
    suspended = false
    updateAnimation()
  }

  @objc private func displayOptionsChanged() { updateAnimation() }

  private func updateAnimation() {
    let visible =
      allowsAnimation && !suspended && !NSApp.isHidden && !isHiddenOrHasHiddenAncestor
      && window?.isVisible == true && window?.isMiniaturized == false
      && window?.occlusionState.contains(.visible) == true
    if visible {
      startMonitoringClicks()
      if !observingDisplayOptions {
        NSWorkspace.shared.notificationCenter.addObserver(
          self, selector: #selector(displayOptionsChanged),
          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        observingDisplayOptions = true
      }
      if !reduceMotion() {
        startAnimation()
        return
      }
    } else {
      stopObservingDisplayOptions()
      stopMonitoringClicks()
    }
    stopAnimation()
  }

  private func startMonitoringClicks() {
    guard clickMonitor == nil,
      window?.toolbar?.items.contains(where: { $0.view === self }) == true
    else { return }
    // Custom-view toolbar items don't forward their native label/padding
    // clicks to the control. Preserve normal NSButton tracking over the
    // icon, and bridge only the remaining part of this item's container.
    clickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      guard let self else { return event }
      return self.handleToolbarClick(event)
    }
  }

  private func handleToolbarClick(_ event: NSEvent) -> NSEvent? {
    guard let window, let container = superview else { return event }
    // The previous release may have occurred in another app. A new press
    // or a different window must never be swallowed by a stale gesture.
    if event.type == .leftMouseDown || event.window !== window { cancelToolbarClick() }
    guard event.window === window else { return event }
    let inside =
      container.bounds.contains(container.convert(event.locationInWindow, from: nil))
    if trackingToolbarClick {
      highlight(inside && isEnabled)
      if event.type == .leftMouseUp {
        trackingToolbarClick = false
        highlight(false)
        if inside && isEnabled { performClick(nil) }
      }
      return nil
    }
    guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control), inside, isEnabled,
      let frameView = window.contentView?.superview
    else { return event }
    let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
    if hit === self || hit?.isDescendant(of: self) == true { return event }
    trackingToolbarClick = true
    highlight(true)
    return nil
  }

  private func stopMonitoringClicks() {
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    cancelToolbarClick()
  }

  @objc private func cancelToolbarClick() {
    guard trackingToolbarClick else { return }
    trackingToolbarClick = false
    highlight(false)
  }

  private func startAnimation() {
    guard !isAnimating else { return }
    isAnimating = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for sparkle in sparkles { sparkle.opacity = 0 }
    CATransaction.commit()
    let epoch = CACurrentMediaTime()
    // Keep the primary star steady. Different periods and pre-advanced phases
    // let the surrounding glints overlap without a marching or breathing beat.
    // Each glint has one soft peak, followed by an invisible reset interval.
    let rhythms: [(period: Double, phase: Double, lifetime: Double, dx: CGFloat, dy: CGFloat)] = [
      (3.7, 1.1, 2.3, -1.6, 2.4), (4.9, 3.0, 2.5, 1.2, 2.0),
      (4.1, 0.4, 2.1, -2.0, 2.8), (5.3, 2.2, 2.6, 1.8, 2.4),
      (3.4, 2.7, 2.0, 2.0, 3.0), (4.6, 1.5, 2.2, -1.2, 2.0),
      (4.3, 3.6, 2.4, -1.6, 2.6),
    ]
    let verticalDirection: CGFloat = (layer?.isGeometryFlipped ?? isFlipped) ? -1 : 1
    for (sparkle, rhythm) in zip(sparkles, rhythms) {
      let end = rhythm.lifetime / rhythm.period
      let times: [NSNumber] = [0, 0.04, end * 0.45, end * 0.65, end, 1].map {
        NSNumber(value: $0)
      }
      let easing = Array(
        repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: times.count - 1)
      let opacity = CAKeyframeAnimation(keyPath: "opacity")
      opacity.values = [0, 0, 1, 0.88, 0, 0]
      opacity.keyTimes = times
      opacity.timingFunctions = easing
      let scale = CAKeyframeAnimation(keyPath: "transform.scale")
      scale.values = [0.35, 0.35, 1.12, 0.98, 0.35, 0.35]
      scale.keyTimes = times
      scale.timingFunctions = easing
      // Drift only a few points upward; reposition while invisible rather
      // than visibly reversing direction. Additive offsets survive layout.
      let start = NSPoint(x: -rhythm.dx / 2, y: -verticalDirection * rhythm.dy / 2)
      let finish = NSPoint(x: rhythm.dx / 2, y: verticalDirection * rhythm.dy / 2)
      let drift = CAKeyframeAnimation(keyPath: "position")
      drift.isAdditive = true
      drift.values = [NSValue(point: start), NSValue(point: finish), NSValue(point: start)]
      drift.keyTimes = [0, NSNumber(value: end), 1]
      let animation = CAAnimationGroup()
      animation.animations = [opacity, scale, drift]
      animation.duration = rhythm.period
      animation.beginTime = epoch - rhythm.phase
      animation.repeatCount = .infinity
      sparkle.add(animation, forKey: "ai.twinkle")
    }
  }

  private func stopAnimation() {
    guard isAnimating else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, sparkle) in sparkles.enumerated() {
      sparkle.removeAnimation(forKey: "ai.twinkle")
      sparkle.opacity = index < 2 ? 0.85 : 0
    }
    CATransaction.commit()
    isAnimating = false
  }

  private func stopObservingDisplayOptions() {
    guard observingDisplayOptions else { return }
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    observingDisplayOptions = false
  }

  private func updateColors() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let gold =
      dark
      ? NSColor(calibratedRed: 1, green: 0.79, blue: 0.16, alpha: 1)
      : NSColor(calibratedRed: 0.98, green: 0.64, blue: 0.02, alpha: 1)
    let brightGold = NSColor(calibratedRed: 1, green: 0.78, blue: 0.12, alpha: 1)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mainStar.fillColor = gold.cgColor
    mainStar.shadowColor = gold.cgColor
    for (index, sparkle) in sparkles.enumerated() {
      sparkle.fillColor = (index.isMultiple(of: 2) ? gold : brightGold).cgColor
    }
    CATransaction.commit()
  }

  private static func starPath(size: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let mid = size / 2
    path.move(to: CGPoint(x: mid, y: size))
    path.addQuadCurve(to: CGPoint(x: size, y: mid), control: CGPoint(x: mid, y: mid))
    path.addQuadCurve(to: CGPoint(x: mid, y: 0), control: CGPoint(x: mid, y: mid))
    path.addQuadCurve(to: CGPoint(x: 0, y: mid), control: CGPoint(x: mid, y: mid))
    path.addQuadCurve(to: CGPoint(x: mid, y: size), control: CGPoint(x: mid, y: mid))
    path.closeSubpath()
    return path
  }

  deinit {
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }
}
