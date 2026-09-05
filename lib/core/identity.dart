import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'settings.dart';

/// A peer we have paired with.
class TrustedPeer {
  TrustedPeer({
    required this.deviceId,
    required this.name,
    required this.publicKey,
  });
  final String deviceId;
  final String name;
  final Uint8List publicKey; // static X25519 public key

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'pk': base64Encode(publicKey),
  };

  static TrustedPeer fromJson(Map<String, dynamic> j) => TrustedPeer(
    deviceId: j['deviceId'] as String,
    name: j['name'] as String,
    publicKey: base64Decode(j['pk'] as String),
  );
}

/// This device's stable identity plus the registry of trusted peers.
/// Stored in preferences (these are keys, not clipboard content).
class Identity extends ChangeNotifier {
  Identity._(this._settings, this.deviceId, this.keyPair, this.publicKey);

  static Future<Identity> load(SettingsStore settings) async {
    var id = settings.getRaw('deviceId');
    if (id == null) {
      id = _randomHex(16);
      await settings.setRaw('deviceId', id);
    }
    var seedB64 = settings.getRaw('x25519Seed');
    if (seedB64 == null) {
      final r = Random.secure();
      final seed = Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
      seedB64 = base64Encode(seed);
      await settings.setRaw('x25519Seed', seedB64);
    }
    final kp = await X25519().newKeyPairFromSeed(base64Decode(seedB64));
    final pk = await kp.extractPublicKey();
    final identity = Identity._(settings, id, kp, Uint8List.fromList(pk.bytes));
    identity._loadTrusted();
    return identity;
  }

  final SettingsStore _settings;
  final String deviceId;
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
  final Map<String, TrustedPeer> _trusted = {};

  List<TrustedPeer> get trustedPeers => _trusted.values.toList();

  TrustedPeer? trustedPeer(String deviceId) => _trusted[deviceId];

  /// True if [deviceId] is trusted AND presents the same static key we paired with.
  bool isTrusted(String deviceId, List<int> publicKey) {
    final t = _trusted[deviceId];
    if (t == null) return false;
    return listEquals(t.publicKey, publicKey);
  }

  Future<void> trust(TrustedPeer peer) async {
    _trusted[peer.deviceId] = peer;
    await _saveTrusted();
    notifyListeners();
  }

  Future<void> forget(String deviceId) async {
    _trusted.remove(deviceId);
    await _saveTrusted();
    notifyListeners();
  }

  void _loadTrusted() {
    final raw = _settings.getRaw('trustedPeers');
    if (raw == null) return;
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    for (final j in list) {
      final p = TrustedPeer.fromJson(j);
      _trusted[p.deviceId] = p;
    }
  }

  Future<void> _saveTrusted() => _settings.setRaw(
    'trustedPeers',
    jsonEncode(_trusted.values.map((p) => p.toJson()).toList()),
  );

  static String _randomHex(int bytes) {
    final r = Random.secure();
    return List.generate(
      bytes,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Short human-readable fingerprint of a public key (for the pairing dialog).
  static String fingerprint(List<int> pk) {
    final hex = pk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 4)}-${hex.substring(4, 8)}-${hex.substring(8, 12)}'
        .toUpperCase();
  }
}
