import 'dart:async';

import 'package:flutter/services.dart';

import '../core/models.dart';

/// Main-engine side of the floating overlay window.
///
/// The overlay is a second Flutter engine hosted in a native borderless,
/// non-activating, always-on-top panel. Native code (`clipsync/overlay`)
/// positions/shows the panel and relays the payload to the overlay engine.
class OverlayChannel {
  OverlayChannel() {
    _m.setMethodCallHandler(_onCall);
  }

  static const MethodChannel _m = MethodChannel('clipsync/overlay');
  final _clicks = StreamController<void>.broadcast();

  /// Fires when the user clicks the popup.
  Stream<void> get clicks => _clicks.stream;

  Future<void> show({
    required ClipItem item,
    required String fromName,
    required PopupPosition position,
    required PopupStyle style,
    required int dismissMs,
    required bool clickToPaste,
    Uint8List? thumbnail,
  }) {
    return _m.invokeMethod('show', {
      'kind': item.kind.name,
      'text': item.kind == ClipKind.text ? item.preview(max: 160) : null,
      'png': item.kind == ClipKind.image ? (thumbnail ?? item.bytes) : null,
      'from': fromName,
      'position': position.name,
      'style': style.name,
      'dismissMs': dismissMs,
      'clickToPaste': clickToPaste,
      // Logical size of the popup card.
      'width': 360.0,
      'height': item.kind == ClipKind.image ? 164.0 : 116.0,
    });
  }

  Future<void> hide() => _m.invokeMethod('hide');

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'clicked') _clicks.add(null);
  }
}

/// Overlay-engine side. Receives payloads from native and reports back.
class OverlayUiChannel {
  OverlayUiChannel() {
    _m.setMethodCallHandler(_onCall);
  }

  static const MethodChannel _m = MethodChannel('clipsync/overlay_ui');
  final _shows = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get shows => _shows.stream;

  /// Tell native the exit animation finished; it hides the panel.
  Future<void> dismissed() => _m.invokeMethod('dismissed');

  /// Tell native the card was clicked (relayed to the main engine).
  Future<void> clicked() => _m.invokeMethod('clicked');

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'show') {
      _shows.add(Map<String, dynamic>.from(call.arguments as Map));
    }
  }
}
