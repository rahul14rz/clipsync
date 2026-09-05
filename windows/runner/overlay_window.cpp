#include "overlay_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <string>

namespace {

constexpr const wchar_t kOverlayClass[] = L"CLIPSYNC_OVERLAY_WINDOW";
constexpr int kMarginDip = 12;
constexpr int kCardInsetDip = 8;   // matches the Padding around the Dart card
constexpr int kCardRadiusDip = 14;

double GetDouble(const flutter::EncodableMap& m, const char* key, double fallback) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* l = std::get_if<int64_t>(&it->second)) return static_cast<double>(*l);
  return fallback;
}

std::string GetString(const flutter::EncodableMap& m, const char* key, const char* fallback) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return fallback;
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return fallback;
}

}  // namespace

OverlayWindow::OverlayWindow(const flutter::DartProject& base_project,
                             flutter::BinaryMessenger* main_messenger) {
  WNDCLASSW wc{};
  wc.lpszClassName = kOverlayClass;
  wc.lpfnWndProc = WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  RegisterClassW(&wc);

  hwnd_ = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kOverlayClass, L"ClipSync Overlay", WS_POPUP,
      0, 0, 340, 96, nullptr, nullptr, GetModuleHandle(nullptr), this);

  flutter::DartProject project = base_project;
  project.set_dart_entrypoint("overlayMain");
  controller_ = std::make_unique<flutter::FlutterViewController>(340, 96, project);
  if (controller_->engine() && controller_->view()) {
    HWND child = controller_->view()->GetNativeWindow();
    SetParent(child, hwnd_);
    MoveWindow(child, 0, 0, 340, 96, TRUE);

    ui_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        controller_->engine()->messenger(), "clipsync/overlay_ui",
        &flutter::StandardMethodCodec::GetInstance());
    ui_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "dismissed") {
        Hide();
        result->Success();
      } else if (call.method_name() == "clicked") {
        if (main_channel_) main_channel_->InvokeMethod("clicked", nullptr);
        result->Success();
      } else {
        result->NotImplemented();
      }
    });
  }

  main_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      main_messenger, "clipsync/overlay", &flutter::StandardMethodCodec::GetInstance());
  main_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "show") {
      const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!map) {
        result->Error("args", "expected map");
        return;
      }
      Show(*map);
      result->Success();
    } else if (call.method_name() == "hide") {
      Hide();
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

OverlayWindow::~OverlayWindow() {
  controller_ = nullptr;
  if (hwnd_) DestroyWindow(hwnd_);
}

void OverlayWindow::Show(const flutter::EncodableMap& args) {
  double width_dip = GetDouble(args, "width", 340);
  double height_dip = GetDouble(args, "height", 96);
  std::string position = GetString(args, "position", "bottomRight");

  POINT cursor{};
  GetCursorPos(&cursor);
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  GetMonitorInfo(monitor, &mi);
  double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;

  int w = static_cast<int>(width_dip * scale);
  int h = static_cast<int>(height_dip * scale);
  int margin = static_cast<int>(kMarginDip * scale);
  const RECT& work = mi.rcWork;
  bool right = position.size() >= 5 && position.compare(position.size() - 5, 5, "Right") == 0;
  bool top = position.rfind("top", 0) == 0;
  int x = right ? work.right - w - margin : work.left + margin;
  int y = top ? work.top + margin : work.bottom - h - margin;

  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
  if (controller_ && controller_->view()) {
    MoveWindow(controller_->view()->GetNativeWindow(), 0, 0, w, h, TRUE);
  }
  // Clip to the rounded card so the padding/shadow area isn't a black box.
  int inset = static_cast<int>(kCardInsetDip * scale);
  int radius = static_cast<int>(kCardRadiusDip * scale);
  HRGN rgn = CreateRoundRectRgn(inset, inset, w - inset + 1, h - inset + 1, radius, radius);
  SetWindowRgn(hwnd_, rgn, TRUE);  // window owns rgn now

  if (ui_channel_) {
    ui_channel_->InvokeMethod(
        "show", std::make_unique<flutter::EncodableValue>(flutter::EncodableValue(args)));
  }
}

void OverlayWindow::Hide() {
  if (hwnd_) ShowWindow(hwnd_, SW_HIDE);
}

LRESULT CALLBACK OverlayWindow::WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return DefWindowProc(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<OverlayWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;  // never steal focus from the user's app
    case WM_SIZE:
      if (self && self->controller_ && self->controller_->view()) {
        RECT rc;
        GetClientRect(hwnd, &rc);
        MoveWindow(self->controller_->view()->GetNativeWindow(), 0, 0,
                   rc.right - rc.left, rc.bottom - rc.top, TRUE);
      }
      return 0;
    case WM_DPICHANGED: {
      auto* rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, nullptr, rect->left, rect->top, rect->right - rect->left,
                   rect->bottom - rect->top, SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}
