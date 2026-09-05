#ifndef RUNNER_OVERLAY_WINDOW_H_
#define RUNNER_OVERLAY_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Borderless, topmost, non-activating tool window hosting a second Flutter
// engine that runs `overlayMain`. Hidden until the main engine calls show().
//
// Main engine  --clipsync/overlay-->  native  --clipsync/overlay_ui-->  overlay engine
class OverlayWindow {
 public:
  OverlayWindow(const flutter::DartProject& base_project,
                flutter::BinaryMessenger* main_messenger);
  ~OverlayWindow();

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);
  void Show(const flutter::EncodableMap& args);
  void Hide();

  HWND hwnd_ = nullptr;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> main_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> ui_channel_;
};

#endif  // RUNNER_OVERLAY_WINDOW_H_
