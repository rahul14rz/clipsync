#ifndef RUNNER_CLIPBOARD_PLUGIN_H_
#define RUNNER_CLIPBOARD_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Full-fidelity clipboard bridge for the main Flutter engine.
//
// MethodChannel  clipsync/clipboard         read / writeText / writeImage / changeCount
// EventChannel   clipsync/clipboard_events  emits GetClipboardSequenceNumber() on change
//
// Change detection is event driven: the owning window registers with
// AddClipboardFormatListener and forwards WM_CLIPBOARDUPDATE to
// OnClipboardUpdate().
class ClipboardPlugin {
 public:
  ClipboardPlugin(flutter::BinaryMessenger* messenger, HWND owner);
  ~ClipboardPlugin();

  // Call from the owner's WM_CLIPBOARDUPDATE handler.
  void OnClipboardUpdate();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::EncodableValue Read();
  bool WriteText(const std::string& utf8);
  bool WriteImage(const std::vector<uint8_t>* png, const std::vector<uint8_t>* bmp);
  bool OpenClipboardRetry();

  HWND owner_;
  UINT png_format_;
  DWORD last_own_sequence_ = 0;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
};

#endif  // RUNNER_CLIPBOARD_PLUGIN_H_
