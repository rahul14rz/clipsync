import 'dart:convert';

import 'package:clipsync/net/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(SessionCipher, SessionCipher)> pair(String pinA, String pinB) async {
  final x = X25519();
  final staticA = await x.newKeyPair();
  final staticB = await x.newKeyPair();
  final hsA = Handshake(staticKeyPair: staticA, isInitiator: true);
  final hsB = Handshake(staticKeyPair: staticB, isInitiator: false);
  final ephA = await hsA.ephemeralPublic();
  final ephB = await hsB.ephemeralPublic();
  final pkA = (await staticA.extractPublicKey()).bytes;
  final pkB = (await staticB.extractPublicKey()).bytes;
  final kA = await hsA.derive(
    remoteEphemeral: ephB,
    remoteStatic: pkB,
    pin: pinA,
  );
  final kB = await hsB.derive(
    remoteEphemeral: ephA,
    remoteStatic: pkA,
    pin: pinB,
  );
  return (SessionCipher(kA), SessionCipher(kB));
}

void main() {
  test('matching PIN yields working bidirectional channel', () async {
    final (a, b) = await pair('123456', '123456');
    final sealed = await a.seal(MsgType.text, utf8.encode('hello'));
    final (type, payload) = await b.open(sealed);
    expect(type, MsgType.text);
    expect(utf8.decode(payload), 'hello');

    final back = await b.seal(MsgType.control, utf8.encode('{"t":"ok"}'));
    final (t2, p2) = await a.open(back);
    expect(t2, MsgType.control);
    expect(utf8.decode(p2), '{"t":"ok"}');
  });

  test('wrong PIN fails authentication', () async {
    final (a, b) = await pair('123456', '123457');
    final sealed = await a.seal(MsgType.text, utf8.encode('hello'));
    expect(() => b.open(sealed), throwsA(isA<SecretBoxAuthenticationError>()));
  });

  test('tampered frame fails authentication', () async {
    final (a, b) = await pair('', '');
    final sealed = await a.seal(MsgType.text, utf8.encode('hello'));
    sealed[15] ^= 0xff;
    expect(() => b.open(sealed), throwsA(isA<SecretBoxAuthenticationError>()));
  });

  test('pin is six digits', () {
    final pin = generatePin();
    expect(pin, matches(RegExp(r'^\d{6}$')));
  });
}
