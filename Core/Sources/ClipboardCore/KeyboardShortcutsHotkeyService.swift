import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts

private func carbonHotkeyEventHandler(
  eventHandlerCall: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  KeyboardShortcutsHotkeyService.handleCarbonHotkeyEvent(event)
}

public final class KeyboardShortcutsHotkeyService: HotkeyService, @unchecked Sendable {
  private static weak var activeService: KeyboardShortcutsHotkeyService?
  private static let hotkeySignature: UInt32 = 0x434C_5042  // "CLPB"
  private static let hotkeyID: UInt32 = 1

  public let events: AsyncStream<Void>
  public let bindingStatus: AsyncStream<BindingStatus>

  private let eventsContinuation: AsyncStream<Void>.Continuation
  private let statusContinuation: AsyncStream<BindingStatus>.Continuation
  private var boundName: KeyboardShortcuts.Name?
  private var eventHandler: EventHandlerRef?
  private var eventHotKey: EventHotKeyRef?
  private var shortcutObserver: NSObjectProtocol?

  public init() {
    let (eventsStream, eventsContinuation) = AsyncStream.makeStream(of: Void.self)
    self.events = eventsStream
    self.eventsContinuation = eventsContinuation

    let (statusStream, statusContinuation) = AsyncStream.makeStream(
      of: BindingStatus.self
    )
    self.bindingStatus = statusStream
    self.statusContinuation = statusContinuation
    statusContinuation.yield(.unbound)
  }

  public func bind(_ name: KeyboardShortcuts.Name) {
    if boundName == nil {
      Self.activeService = self
    }
    if boundName != name {
      unregisterShortcutChangeObserver()
      unregisterCarbonHotkey()
      boundName = name
      shortcutObserver = NotificationCenter.default.addObserver(
        forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
        object: nil,
        queue: nil
      ) { [weak self] notification in
        guard
          let changedName = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
          changedName == name
        else { return }
        self?.registerCarbonHotkey(name)
      }
    }
    registerCarbonHotkey(name)
  }

  private func registerCarbonHotkey(_ name: KeyboardShortcuts.Name) {
    unregisterCarbonHotkey()
    let shortcut = KeyboardShortcuts.getShortcut(for: name)
    guard let shortcut else {
      Log.hotkey.info("hotkey.unbound name=\(name.rawValue, privacy: .public)")
      statusContinuation.yield(.unbound)
      return
    }

    var eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      )
    ]
    var handler: EventHandlerRef?
    let eventTarget = GetApplicationEventTarget()
    let handlerError = InstallEventHandler(
      eventTarget,
      carbonHotkeyEventHandler,
      eventTypes.count,
      &eventTypes,
      nil,
      &handler
    )
    guard handlerError == noErr, let handler else {
      Log.hotkey.error(
        "hotkey.handler_failed name=\(name.rawValue, privacy: .public) err=\(handlerError)"
      )
      statusContinuation.yield(.conflict("Carbon handler error \(handlerError)"))
      return
    }
    eventHandler = handler

    var hotKey: EventHotKeyRef?
    let registerError = RegisterEventHotKey(
      UInt32(shortcut.carbonKeyCode),
      UInt32(shortcut.carbonModifiers),
      EventHotKeyID(signature: Self.hotkeySignature, id: Self.hotkeyID),
      eventTarget,
      0,
      &hotKey
    )
    guard registerError == noErr, let hotKey else {
      RemoveEventHandler(handler)
      eventHandler = nil
      Log.hotkey.error(
        "hotkey.register_failed name=\(name.rawValue, privacy: .public) err=\(registerError)"
      )
      statusContinuation.yield(.conflict("Carbon register error \(registerError)"))
      return
    }
    eventHotKey = hotKey
    Log.hotkey.info(
      "hotkey.bound name=\(name.rawValue, privacy: .public)"
    )
    statusContinuation.yield(.ok)
  }

  public func unbind() {
    unregisterShortcutChangeObserver()
    unregisterCarbonHotkey()
    boundName = nil
    if Self.activeService === self {
      Self.activeService = nil
    }
    statusContinuation.yield(.unbound)
  }

  private func unregisterCarbonHotkey() {
    if let eventHotKey {
      UnregisterEventHotKey(eventHotKey)
      self.eventHotKey = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  private func unregisterShortcutChangeObserver() {
    if let shortcutObserver {
      NotificationCenter.default.removeObserver(shortcutObserver)
      self.shortcutObserver = nil
    }
  }

  fileprivate static func handleCarbonHotkeyEvent(_ event: EventRef?) -> OSStatus {
    guard let event else {
      Log.hotkey.info("hotkey.event_missing")
      return OSStatus(eventNotHandledErr)
    }
    var hotkeyID = EventHotKeyID()
    let error = GetEventParameter(
      event,
      UInt32(kEventParamDirectObject),
      UInt32(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotkeyID
    )
    guard error == noErr else {
      Log.hotkey.error("hotkey.event_parameter_failed err=\(error)")
      return error
    }
    guard hotkeyID.signature == hotkeySignature, hotkeyID.id == Self.hotkeyID else {
      Log.hotkey.info(
        "hotkey.event_ignored signature=\(hotkeyID.signature) id=\(hotkeyID.id)"
      )
      return OSStatus(eventNotHandledErr)
    }
    Log.hotkey.info("hotkey.event_received")
    activeService?.eventsContinuation.yield(())
    return noErr
  }

  deinit {
    unbind()
    eventsContinuation.finish()
    statusContinuation.finish()
  }
}
