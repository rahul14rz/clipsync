import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../core/models.dart';

/// Dart side of the native clipboard bridge.
///
/// Native contract (`clipsync/clipboard`):
///  * `read()` -> `{type: 'text'|'image'|'none', text?: String, png?: bytes, bmp?: bytes}`
///    Windows may return `bmp` (a full BMP file) when no PNG format is on the
///    clipboard; it is converted to PNG here so the wire format is always PNG.
///  * `writeText(String)`
///  * `writeImage({png: bytes, bmp?: bytes})` — Windows also gets a BMP so it
///    can publish CF_DIB alongside the registered "PNG" format.
///  * `changeCount()` -> int
///
/// `clipsync/clipboard_events` emits the new change count whenever the OS
/// clipboard changes (WM_CLIPBOARDUPDATE on Windows; NSPasteboard.changeCount
/// watcher on macOS).
class ClipboardChannel {
  static const MethodChannel _m = MethodChannel('clipsync/clipboard');
  static const EventChannel _e = EventChannel('clipsync/clipboard_events');

  Stream<int>? _changes;

  Stream<int> get changes =>
      _changes ??= _e.receiveBroadcastStream().map((e) => (e as num).toInt());

  Future<int> changeCount() async =>
      (await _m.invokeMethod<int>('changeCount')) ?? 0;

  Future<ClipItem?> read() async {
    final res = await _m.invokeMapMethod<String, dynamic>('read');
    if (res == null) return null;
    switch (res['type']) {
      case 'text':
        final t = res['text'] as String?;
        if (t == null || t.isEmpty) return null;
        return ClipItem.text(t);
      case 'image':
        final png = res['png'] as Uint8List?;
        if (png != null && png.isNotEmpty) return ClipItem.imagePng(png);
        final bmp = res['bmp'] as Uint8List?;
        if (bmp != null && bmp.isNotEmpty) {
          final converted = await compute(_bmpToPng, bmp);
          if (converted != null) return ClipItem.imagePng(converted);
        }
        return null;
      default:
        return null;
    }
  }

  Future<void> writeText(String text) => _m.invokeMethod('writeText', text);

  Future<void> writeImage(Uint8List png) async {
    Uint8List? bmp;
    if (Platform.isWindows) {
      bmp = await compute(_pngToBmp, png);
    }
    await _m.invokeMethod('writeImage', {'png': png, 'bmp': bmp});
  }

  Future<void> write(ClipItem item) => switch (item.kind) {
    ClipKind.text => writeText(item.text),
    ClipKind.image => writeImage(item.bytes),
  };
}

Uint8List? _bmpToPng(Uint8List bmp) {
  final decoded = img.decodeBmp(bmp);
  if (decoded == null) return null;
  return Uint8List.fromList(img.encodePng(decoded));
}

Uint8List? _pngToBmp(Uint8List png) {
  final decoded = img.decodePng(png);
  if (decoded == null) return null;
  return Uint8List.fromList(img.encodeBmp(decoded));
}
