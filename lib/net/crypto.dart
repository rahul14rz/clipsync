import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Wire protocol version.
const int kProtocolVersion = 1;

/// Plaintext message types inside an encrypted frame.
class MsgType {
  static const int control = 0x00; // JSON
  static const int text = 0x01; // UTF-8
  static const int imagePng = 0x02; // PNG bytes
}

/// Result of a completed key agreement: one key per direction.
class SessionKeys {
  SessionKeys({required this.sendKey, required this.recvKey});
  final SecretKey sendKey;
  final SecretKey recvKey;
}

/// Key agreement helper shared by both sides.
///
/// Both sides exchange an ephemeral X25519 key plus their static X25519 key.
/// The shared secret is `X25519(eph, eph') || X25519(static, static')`, run
/// through HKDF-SHA256 with the pairing PIN as salt (empty when both sides
/// already trust each other). A wrong PIN produces a different key, so the
/// first AEAD frame fails to authenticate and the connection is dropped.
class Handshake {
  Handshake({required this.staticKeyPair, required this.isInitiator});

  final SimpleKeyPair staticKeyPair;
  final bool isInitiator;
  final X25519 _x = X25519();
  SimpleKeyPair? _eph;

  Future<Uint8List> ephemeralPublic() async {
    _eph ??= await _x.newKeyPair();
    final pk = await _eph!.extractPublicKey();
    return Uint8List.fromList(pk.bytes);
  }

  Future<SessionKeys> derive({
    required List<int> remoteEphemeral,
    required List<int> remoteStatic,
    required String pin,
  }) async {
    final eph = _eph ??= await _x.newKeyPair();
    final ss1 = await _x.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(
        remoteEphemeral,
        type: KeyPairType.x25519,
      ),
    );
    final ss2 = await _x.sharedSecretKey(
      keyPair: staticKeyPair,
      remotePublicKey: SimplePublicKey(remoteStatic, type: KeyPairType.x25519),
    );
    final ikm = <int>[...await ss1.extractBytes(), ...await ss2.extractBytes()];
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final salt = utf8.encode(pin);
    final kInit = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: salt,
      info: utf8.encode('clipsync-v$kProtocolVersion-i2r'),
    );
    final kResp = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: salt,
      info: utf8.encode('clipsync-v$kProtocolVersion-r2i'),
    );
    return isInitiator
        ? SessionKeys(sendKey: kInit, recvKey: kResp)
        : SessionKeys(sendKey: kResp, recvKey: kInit);
  }
}

/// Per-connection authenticated encryption. Frame body layout:
/// `nonce(12) || ciphertext || tag(16)`.
class SessionCipher {
  SessionCipher(this.keys);
  final SessionKeys keys;
  final Chacha20 _aead = Chacha20.poly1305Aead();

  Future<Uint8List> seal(int type, List<int> payload) async {
    final plain = Uint8List(1 + payload.length)
      ..[0] = type
      ..setRange(1, 1 + payload.length, payload);
    final box = await _aead.encrypt(plain, secretKey: keys.sendKey);
    return Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Returns (type, payload). Throws [SecretBoxAuthenticationError] on a bad key/tag.
  Future<(int, Uint8List)> open(Uint8List body) async {
    if (body.length < 12 + 16 + 1) {
      throw const FormatException('encrypted frame too short');
    }
    final nonce = body.sublist(0, 12);
    final mac = Mac(body.sublist(body.length - 16));
    final ct = body.sublist(12, body.length - 16);
    final plain = await _aead.decrypt(
      SecretBox(ct, nonce: nonce, mac: mac),
      secretKey: keys.recvKey,
    );
    return (plain[0], Uint8List.fromList(plain.sublist(1)));
  }
}

/// Generates a 6-digit pairing PIN.
String generatePin() {
  final r = SecureRandom.fast;
  return List.generate(6, (_) => r.nextInt(10)).join();
}
