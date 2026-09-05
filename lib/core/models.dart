import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Kind of clipboard payload carried over the wire.
enum ClipKind { text, image }

/// An in-memory clipboard item. Never persisted anywhere.
class ClipItem {
  ClipItem._(this.kind, this.bytes, this.sha256, this.sourceDeviceId, this.at);

  factory ClipItem.text(String text, {String sourceDeviceId = ''}) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    return ClipItem._(
      ClipKind.text,
      bytes,
      hashBytes(bytes),
      sourceDeviceId,
      DateTime.now(),
    );
  }

  factory ClipItem.imagePng(Uint8List png, {String sourceDeviceId = ''}) {
    return ClipItem._(
      ClipKind.image,
      png,
      hashBytes(png),
      sourceDeviceId,
      DateTime.now(),
    );
  }

  final ClipKind kind;

  /// UTF-8 text or PNG bytes depending on [kind].
  final Uint8List bytes;

  /// Hex SHA-256 of [bytes]; used for loop prevention.
  final String sha256;

  /// Device id that originally produced this item ('' for local).
  final String sourceDeviceId;
  final DateTime at;

  String get text => kind == ClipKind.text ? utf8.decode(bytes) : '';

  /// Short preview for the overlay / peer list.
  String preview({int max = 140}) {
    if (kind == ClipKind.image) return 'Image (${_humanSize(bytes.length)})';
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  static String hashBytes(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

  static String _humanSize(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Where the floating popup docks.
enum PopupPosition { topLeft, topRight, bottomLeft, bottomRight }

/// How the popup animates in.
enum PopupStyle { corner, edgeSlide }

/// A peer as seen by the UI.
enum PeerStatus { discovered, connecting, pairing, connected, offline }

class PeerInfo {
  PeerInfo({
    required this.deviceId,
    required this.name,
    required this.status,
    this.trusted = false,
    this.address,
    this.port,
    this.lastError,
  });

  final String deviceId;
  final String name;
  final PeerStatus status;
  final bool trusted;
  final String? address;
  final int? port;
  final String? lastError;
}

/// Small fixed-size set of recently seen hashes (loop prevention).
class RecentHashes {
  RecentHashes(this.capacity);
  final int capacity;
  final List<String> _items = [];

  void add(String h) {
    _items.remove(h);
    _items.add(h);
    if (_items.length > capacity) _items.removeAt(0);
  }

  bool contains(String h) => _items.contains(h);
}
