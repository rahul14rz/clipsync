import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var clipboardPlugin: ClipboardPlugin?
  private var overlayPanel: OverlayPanel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    clipboardPlugin = ClipboardPlugin.register(with: messenger)
    SystemPlugin.register(with: messenger)
    overlayPanel = OverlayPanel(mainMessenger: messenger)

    super.awakeFromNib()
  }
}
