#ifndef RUNNER_SYSTEM_PLUGIN_H_
#define RUNNER_SYSTEM_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// `clipsync/system`: beep, accessibility (always granted on Windows),
// simulated Ctrl+V via SendInput, no-op dock toggle.
class SystemPlugin {
 public:
  explicit SystemPlugin(flutter::BinaryMessenger* messenger);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool SimulatePaste();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SYSTEM_PLUGIN_H_
