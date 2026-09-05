import Cocoa
import FlutterMacOS

/// Borderless, non-activating, always-on-top panel hosting a second Flutter
/// engine (`overlayMain`). Hidden until content arrives from a peer.
///
/// Main engine  --clipsync/overlay-->  native  --clipsync/overlay_ui-->  overlay engine
///   show(payload)                     position+orderFront, relay `show`
///   hide()                            orderOut
///   <- clicked                        <- clicked
///                                     <- dismissed (orderOut)
final class OverlayPanel: NSObject {
  private let panel: NSPanel
  private let engine: FlutterEngine
  private let controller: FlutterViewController
  private let uiChannel: FlutterMethodChannel
  private let mainChannel: FlutterMethodChannel

  init(mainMessenger: FlutterBinaryMessenger) {
    engine = FlutterEngine(name: "clipsync.overlay", project: nil)
    engine.run(withEntrypoint: "overlayMain")
    controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    controller.backgroundColor = .clear

    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false // the Flutter card draws its own shadow
    panel.isMovableByWindowBackground = false
    panel.acceptsMouseMovedEvents = true
    panel.isReleasedWhenClosed = false
    panel.contentViewController = controller

    uiChannel = FlutterMethodChannel(name: "clipsync/overlay_ui", binaryMessenger: engine.binaryMessenger)
    mainChannel = FlutterMethodChannel(name: "clipsync/overlay", binaryMessenger: mainMessenger)
    super.init()

    mainChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "show":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "args", message: "expected map", details: nil)); return
        }
        self.show(args)
        result(nil)
      case "hide":
        self.panel.orderOut(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    uiChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "dismissed":
        self.panel.orderOut(nil)
        result(nil)
      case "clicked":
        self.mainChannel.invokeMethod("clicked", arguments: nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func show(_ args: [String: Any]) {
    let width = CGFloat((args["width"] as? Double) ?? 340)
    let height = CGFloat((args["height"] as? Double) ?? 96)
    let position = (args["position"] as? String) ?? "bottomRight"
    let screen = screenUnderMouse()
    let visible = screen.visibleFrame
    let margin: CGFloat = 12

    let x = position.hasSuffix("Right") ? visible.maxX - width - margin : visible.minX + margin
    let y = position.hasPrefix("top") ? visible.maxY - height - margin : visible.minY + margin
    panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    panel.orderFrontRegardless()
    uiChannel.invokeMethod("show", arguments: args)
  }

  private func screenUnderMouse() -> NSScreen {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main ?? NSScreen.screens[0]
  }
}
