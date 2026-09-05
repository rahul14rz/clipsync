#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "clipboard_plugin.h"
#include "overlay_window.h"
#include "system_plugin.h"
#include "win32_window.h"

// The main window: hosts the primary Flutter view, owns the clipboard
// listener, the system helper channel and the floating overlay window.
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<ClipboardPlugin> clipboard_plugin_;
  std::unique_ptr<SystemPlugin> system_plugin_;
  std::unique_ptr<OverlayWindow> overlay_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
