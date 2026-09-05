import Cocoa
import FlutterMacOS

/// Full-fidelity clipboard access for the main Flutter engine.
///
/// MethodChannel `clipsync/clipboard`:
///   read()            -> {type: text|image|none, text?, png?}
///   writeText(String)
///   writeImage({png})
///   changeCount()     -> Int
/// EventChannel `clipsync/clipboard_events`: emits the new changeCount.
///
/// macOS has no pasteboard-change notification; the cheapest correct
/// approach is to compare `NSPasteboard.general.changeCount` (an integer,
/// no content read) on a short timer.
final class ClipboardPlugin: NSObject, FlutterStreamHandler {
  private let pasteboard = NSPasteboard.general
  private var timer: Timer?
  private var lastCount: Int
  private var sink: FlutterEventSink?

  override init() {
    lastCount = NSPasteboard.general.changeCount
    super.init()
  }

  static func register(with messenger: FlutterBinaryMessenger) -> ClipboardPlugin {
    let plugin = ClipboardPlugin()
    let method = FlutterMethodChannel(name: "clipsync/clipboard", binaryMessenger: messenger)
    method.setMethodCallHandler(plugin.handle)
    let events = FlutterEventChannel(name: "clipsync/clipboard_events", binaryMessenger: messenger)
    events.setStreamHandler(plugin)
    return plugin
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    lastCount = pasteboard.changeCount
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      self?.poll()
    }
    timer?.tolerance = 0.05
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    sink = nil
    return nil
  }

  private func poll() {
    let c = pasteboard.changeCount
    if c != lastCount {
      lastCount = c
      sink?(c)
    }
  }

  // MARK: - Methods

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "changeCount":
      result(pasteboard.changeCount)
    case "read":
      result(read())
    case "writeText":
      guard let text = call.arguments as? String else {
        result(FlutterError(code: "args", message: "expected String", details: nil)); return
      }
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
      lastCount = pasteboard.changeCount // our own write: don't re-emit as a change
      result(nil)
    case "writeImage":
      guard let args = call.arguments as? [String: Any],
            let png = (args["png"] as? FlutterStandardTypedData)?.data else {
        result(FlutterError(code: "args", message: "expected {png}", details: nil)); return
      }
      pasteboard.clearContents()
      pasteboard.setData(png, forType: .png)
      if let image = NSImage(data: png), let tiff = image.tiffRepresentation {
        pasteboard.setData(tiff, forType: .tiff)
      }
      lastCount = pasteboard.changeCount
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func read() -> [String: Any] {
    let types = pasteboard.types ?? []
    // Text wins when present (rich copies often carry an image too).
    if types.contains(.string), let s = pasteboard.string(forType: .string), !s.isEmpty {
      return ["type": "text", "text": s]
    }
    if types.contains(.png), let png = pasteboard.data(forType: .png), !png.isEmpty {
      return ["type": "image", "png": FlutterStandardTypedData(bytes: png)]
    }
    if types.contains(.tiff), let tiff = pasteboard.data(forType: .tiff),
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
      return ["type": "image", "png": FlutterStandardTypedData(bytes: png)]
    }
    return ["type": "none"]
  }
}
