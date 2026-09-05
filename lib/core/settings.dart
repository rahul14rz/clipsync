import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Lets several instances run on one machine during development by
/// namespacing every persisted key: `--dart-define=CLIPSYNC_INSTANCE=b`.
/// Also honoured as a process environment variable so one build can be
/// launched twice for testing.
final String kInstance = const String.fromEnvironment('CLIPSYNC_INSTANCE').isNotEmpty
    ? const String.fromEnvironment('CLIPSYNC_INSTANCE')
    : (Platform.environment['CLIPSYNC_INSTANCE'] ?? '');

/// Persisted user settings. Only settings live here; clipboard content never
/// goes through this class.
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._prefs);

  static Future<SettingsStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = SettingsStore._(prefs);
    if (s.deviceName.isEmpty) {
      var host = Platform.localHostname;
      if (host.endsWith('.local')) host = host.substring(0, host.length - 6);
      await s.setDeviceName(kInstance.isEmpty ? host : '$host-$kInstance');
    }
    return s;
  }

  final SharedPreferences _prefs;

  static String k(String key) => kInstance.isEmpty ? key : '$kInstance.$key';

  String get deviceName => _prefs.getString(k('deviceName')) ?? '';
  Future<void> setDeviceName(String v) => _set(k('deviceName'), v);

  PopupPosition get popupPosition =>
      PopupPosition.values[_prefs.getInt(k('popupPosition')) ??
          PopupPosition.bottomRight.index];
  Future<void> setPopupPosition(PopupPosition v) =>
      _set(k('popupPosition'), v.index);

  PopupStyle get popupStyle =>
      PopupStyle.values[_prefs.getInt(k('popupStyle')) ?? 0];
  Future<void> setPopupStyle(PopupStyle v) => _set(k('popupStyle'), v.index);

  /// 0 means never auto-dismiss.
  int get dismissMs => _prefs.getInt(k('dismissMs')) ?? 5000;
  Future<void> setDismissMs(int v) => _set(k('dismissMs'), v);

  bool get soundEnabled => _prefs.getBool(k('soundEnabled')) ?? true;
  Future<void> setSoundEnabled(bool v) => _set(k('soundEnabled'), v);

  /// Option A (auto-paste on click). Off by default for a frictionless first run.
  bool get clickToPaste => _prefs.getBool(k('clickToPaste')) ?? false;
  Future<void> setClickToPaste(bool v) => _set(k('clickToPaste'), v);

  bool get syncImages => _prefs.getBool(k('syncImages')) ?? true;
  Future<void> setSyncImages(bool v) => _set(k('syncImages'), v);

  bool get showPopup => _prefs.getBool(k('showPopup')) ?? true;
  Future<void> setShowPopup(bool v) => _set(k('showPopup'), v);

  bool get launchAtLogin => _prefs.getBool(k('launchAtLogin')) ?? false;
  Future<void> setLaunchAtLogin(bool v) => _set(k('launchAtLogin'), v);

  bool get syncPaused => _prefs.getBool(k('syncPaused')) ?? false;
  Future<void> setSyncPaused(bool v) => _set(k('syncPaused'), v);

  // Raw access used by Identity for keys/trusted peers.
  String? getRaw(String key) => _prefs.getString(k(key));
  Future<void> setRaw(String key, String value) => _set(k(key), value);
  Future<void> removeRaw(String key) async {
    await _prefs.remove(k(key));
    notifyListeners();
  }

  Future<void> _set(String key, Object v) async {
    switch (v) {
      case String s:
        await _prefs.setString(key, s);
      case int i:
        await _prefs.setInt(key, i);
      case bool b:
        await _prefs.setBool(key, b);
      default:
        throw ArgumentError('unsupported');
    }
    notifyListeners();
  }
}
