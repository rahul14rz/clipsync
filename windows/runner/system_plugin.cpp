#include "system_plugin.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

SystemPlugin::SystemPlugin(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "clipsync/system", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
}

void SystemPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& m = call.method_name();
  if (m == "beep") {
    MessageBeep(MB_OK);
    result->Success();
  } else if (m == "isAccessibilityTrusted") {
    result->Success(flutter::EncodableValue(true));
  } else if (m == "requestAccessibility") {
    result->Success();
  } else if (m == "simulatePaste") {
    result->Success(flutter::EncodableValue(SimulatePaste()));
  } else if (m == "setDockVisible") {
    result->Success();
  } else {
    result->NotImplemented();
  }
}

// Sends Ctrl+V to the foreground window. The overlay is WS_EX_NOACTIVATE so
// the user's app keeps the foreground when they click the popup.
bool SystemPlugin::SimulatePaste() {
  INPUT inputs[4] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = VK_CONTROL;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = 'V';
  inputs[2].type = INPUT_KEYBOARD;
  inputs[2].ki.wVk = 'V';
  inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
  inputs[3].type = INPUT_KEYBOARD;
  inputs[3].ki.wVk = VK_CONTROL;
  inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
  return SendInput(4, inputs, sizeof(INPUT)) == 4;
}
