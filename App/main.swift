import AppKit
import Foundation

// MARK: - Single-instance enforcement
//
// Run this BEFORE NSApplication is created. If another process with
// the same bundle identifier is already alive, bring it to the
// foreground, broadcast a reopen notification, and exit — avoiding
// two Monitors racing over the same pasteboard and two stores
// fighting over the same history.json / blobs tree.

let bundleID = Bundle.main.bundleIdentifier ?? "com.clipboard.app"
let allowMultiple = ProcessInfo.processInfo.environment["CLIPBOARD_ALLOW_MULTIPLE"] == "1"

if !allowMultiple {
  let selfPID = ProcessInfo.processInfo.processIdentifier
  let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != selfPID }

  if let existing = peers.first {
    existing.activate(options: [.activateAllWindows])
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("com.clipboard.app.reopen"),
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
    exit(0)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
