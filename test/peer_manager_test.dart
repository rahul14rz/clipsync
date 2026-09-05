import 'dart:async';
import 'dart:typed_data';

import 'package:clipsync/core/identity.dart';
import 'package:clipsync/core/models.dart';
import 'package:clipsync/core/settings.dart';
import 'package:clipsync/net/peer_connection.dart';
import 'package:clipsync/net/peer_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scripted pairing: the responder's PIN is handed to the initiator through
/// [pinBox]; [initiatorPin] overrides it to simulate a typo.
class ScriptedDelegate implements PairingDelegate {
  ScriptedDelegate(this.pinBox, {this.initiatorPin});
  final Completer<String> pinBox;
  final String? initiatorPin;
  int shown = 0;
  int entered = 0;

  @override
  Future<bool> showPin(RemoteHello remote, String pin, Future<void> done) async {
    shown++;
    if (!pinBox.isCompleted) pinBox.complete(pin);
    await done;
    return true;
  }

  @override
  Future<String?> enterPin(RemoteHello remote) async {
    entered++;
    return initiatorPin ?? await pinBox.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('two managers pair with PIN, trust each other and exchange clips',
      () async {
    final pinBox = Completer<String>();
    final dA = ScriptedDelegate(pinBox);
    final dB = ScriptedDelegate(pinBox);

    // Both managers share one SharedPreferences store in tests, so give the
    // second one a distinct id by loading it after overriding the key.
    final settingsA = await SettingsStore.load();
    await settingsA.setRaw('deviceId', 'a' * 32);
    final idA = await Identity.load(settingsA);
    final a = PeerManager(identity: idA, settings: settingsA, pairingDelegate: dA);
    await a.start();

    // Second identity: separate seed + id so it is a different device.
    await settingsA.setRaw('deviceId', 'b' * 32);
    await settingsA.removeRaw('x25519Seed');
    final idB = await Identity.load(settingsA);
    final b = PeerManager(identity: idB, settings: settingsA, pairingDelegate: dB);
    await b.start();
    expect(idA.deviceId, isNot(idB.deviceId));

    final received = <ClipItem>[];
    b.incoming.listen(received.add);

    await a.connectManual('127.0.0.1', b.port);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(a.connectedCount, 1, reason: 'A should be connected to B');
    expect(b.connectedCount, 1, reason: 'B should be connected to A');
    expect(dB.shown, 1, reason: 'responder displayed a PIN');
    expect(dA.entered, 1, reason: 'initiator entered the PIN');
    expect(idA.trustedPeer(idB.deviceId), isNotNull);
    expect(idB.trustedPeer(idA.deviceId), isNotNull);

    await a.broadcast(ClipItem.text('hello from A'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received.length, 1);
    expect(received.single.text, 'hello from A');
    expect(received.single.sourceDeviceId, idA.deviceId);

    final png = List<int>.generate(50000, (i) => i % 251);
    await a.broadcast(ClipItem.imagePng(Uint8List.fromList(png)));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(received.length, 2);
    expect(received.last.kind, ClipKind.image);
    expect(received.last.bytes, png);

    await a.dispose();
    await b.dispose();
  });

  test('wrong PIN is rejected and nothing is trusted', () async {
    final pinBox = Completer<String>();
    final dA = ScriptedDelegate(pinBox, initiatorPin: '000000');
    final dB = ScriptedDelegate(pinBox);

    final settings = await SettingsStore.load();
    await settings.setRaw('deviceId', 'c' * 32);
    final idA = await Identity.load(settings);
    final a = PeerManager(identity: idA, settings: settings, pairingDelegate: dA);
    await a.start();
    await settings.setRaw('deviceId', 'd' * 32);
    await settings.removeRaw('x25519Seed');
    final idB = await Identity.load(settings);
    final b = PeerManager(identity: idB, settings: settings, pairingDelegate: dB);
    await b.start();

    await a.connectManual('127.0.0.1', b.port);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(a.connectedCount, 0);
    expect(b.connectedCount, 0);
    expect(idA.trustedPeer(idB.deviceId), isNull);
    expect(idB.trustedPeer(idA.deviceId), isNull);

    await a.dispose();
    await b.dispose();
  });
}
