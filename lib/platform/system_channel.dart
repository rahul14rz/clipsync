import 'package:flutter/services.dart';

/// Miscellaneous OS glue (`clipsync/system`).
class SystemChannel {
  static const MethodChannel _m = MethodChannel('clipsync/system');

  /// Plays the system alert sound (NSSound.beep / MessageBeep).
  Future<void> beep() => _m.invokeMethod('beep');

  /// macOS: whether Accessibility access is granted. Windows: always true.
  Future<bool> isAccessibilityTrusted() async =>
      (await _m.invokeMethod<bool>('isAccessibilityTrusted')) ?? true;

  /// macOS: shows the system prompt / opens Privacy settings.
  Future<void> requestAccessibility() =>
      _m.invokeMethod('requestAccessibility');

  /// Sends Cmd+V / Ctrl+V to the frontmost application.
  Future<bool> simulatePaste() async =>
      (await _m.invokeMethod<bool>('simulatePaste')) ?? false;

  /// macOS: hide/show the Dock icon when the main window is hidden/shown.
  Future<void> setDockVisible(bool visible) =>
      _m.invokeMethod('setDockVisible', visible);
}
