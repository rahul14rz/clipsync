import Cocoa
import FlutterMacOS
import ApplicationServices
import ServiceManagement

/// Misc OS glue (`clipsync/system`): beep, Accessibility check/prompt,
/// simulated ⌘V, Dock icon visibility. Also serves the `launch_at_startup`
/// channel that the Dart package expects the host app to provide on macOS.
final class SystemPlugin: NSObject {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "clipsync/system", binaryMessenger: messenger)
    let plugin = SystemPlugin()
    channel.setMethodCallHandler(plugin.handle)

    let launch = FlutterMethodChannel(name: "launch_at_startup", binaryMessenger: messenger)
    launch.setMethodCallHandler(plugin.handleLaunchAtStartup)
  }

  // MARK: - launch_at_startup (SMAppService, macOS 13+)

  private func handleLaunchAtStartup(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(macOS 13.0, *) else {
      result(call.method == "launchAtStartupIsEnabled" ? false : nil)
      return
    }
    switch call.method {
    case "launchAtStartupIsEnabled":
      result(SMAppService.mainApp.status == .enabled)
    case "launchAtStartupSetEnabled":
      let enable = (call.arguments as? [String: Any])?["setEnabledValue"] as? Bool ?? false
      do {
        if enable {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
        result(nil)
      } catch {
        result(FlutterError(code: "launch_at_startup", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "beep":
      NSSound.beep()
      result(nil)
    case "isAccessibilityTrusted":
      result(AXIsProcessTrusted())
    case "requestAccessibility":
      let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      let trusted = AXIsProcessTrustedWithOptions(opts)
      if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
      }
      result(trusted)
    case "simulatePaste":
      result(simulatePaste())
    case "setDockVisible":
      let visible = (call.arguments as? Bool) ?? true
      NSApp.setActivationPolicy(visible ? .regular : .accessory)
      if visible { NSApp.activate(ignoringOtherApps: true) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Posts ⌘V to the frontmost application. The overlay panel is
  /// non-activating so the user's previous app still has focus.
  private func simulatePaste() -> Bool {
    guard AXIsProcessTrusted() else { return false }
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
    let vKey: CGKeyCode = 9 // kVK_ANSI_V
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else {
      return false
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    // Small delay lets the click on the panel finish before the keystroke lands.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
    }
    return true
  }
}
