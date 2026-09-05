import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/identity.dart';
import '../core/models.dart';
import 'crypto.dart';
import 'frame_codec.dart';

/// What the remote side announced in its HELLO.
class RemoteHello {
  RemoteHello({
    required this.deviceId,
    required this.name,
    required this.staticKey,
    required this.ephemeralKey,
  });
  final String deviceId;
  final String name;
  final Uint8List staticKey;
  final Uint8List ephemeralKey;
}

/// Hooks the connection needs from the app while pairing.
abstract class PairingDelegate {
  /// Responder side: display [pin] for [remote]. Return a future that completes
  /// when the dialog is closed (the value is ignored); throw/complete with
  /// `false` to refuse pairing.
  Future<bool> showPin(RemoteHello remote, String pin, Future<void> done);

  /// Initiator side: ask the user for the PIN shown on [remote]. `null` cancels.
  Future<String?> enterPin(RemoteHello remote);
}

class PeerDisconnected implements Exception {
  PeerDisconnected(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// One encrypted TCP link to a peer.
///
/// Flow: HELLO (plain) → MODE (plain, "do I already trust you?") →
/// [optional PIN pairing] → CONFIRM (encrypted) → stream of clip frames.
class PeerConnection {
  PeerConnection._(
    this._socket,
    this.isInitiator,
    this._identity,
    this._localName,
  );

  static Future<PeerConnection> dial(
    String host,
    int port, {
    required Identity identity,
    required String localName,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.setOption(SocketOption.tcpNoDelay, true);
    return PeerConnection._(s, true, identity, localName);
  }

  static PeerConnection accept(
    Socket s, {
    required Identity identity,
    required String localName,
  }) {
    s.setOption(SocketOption.tcpNoDelay, true);
    return PeerConnection._(s, false, identity, localName);
  }

  final Socket _socket;
  final bool isInitiator;
  final Identity _identity;
  final String _localName;

  late final StreamQueue _frames = StreamQueue(
    _socket.transform(frameTransformer()),
  );
  final _items = StreamController<ClipItem>();
  final _closed = Completer<String>();

  RemoteHello? remote;
  SessionCipher? _cipher;
  bool _pairedThisSession = false;
  bool _isClosed = false;

  /// Items received from the peer (already authenticated).
  Stream<ClipItem> get items => _items.stream;

  /// Completes with a reason once the socket is gone.
  Future<String> get onClose => _closed.future;

  bool get isOpen => !_isClosed && _cipher != null;
  bool get pairedThisSession => _pairedThisSession;
  String get remoteAddress => _socket.remoteAddress.address;

  /// Sends HELLO and reads the remote HELLO. Returns the remote identity so the
  /// manager can dedupe connections before pairing UI appears.
  Future<RemoteHello> hello() async {
    final hs = _handshake = Handshake(
      staticKeyPair: _identity.keyPair,
      isInitiator: isInitiator,
    );
    _sendPlain({
      'v': kProtocolVersion,
      'deviceId': _identity.deviceId,
      'name': _localName,
      'spk': base64Encode(_identity.publicKey),
      'epk': base64Encode(await hs.ephemeralPublic()),
    });
    final j = await _readJson();
    if (j['v'] != kProtocolVersion) throw PeerDisconnected('protocol mismatch');
    final r = RemoteHello(
      deviceId: j['deviceId'] as String,
      name: (j['name'] as String?) ?? 'Unknown',
      staticKey: base64Decode(j['spk'] as String),
      ephemeralKey: base64Decode(j['epk'] as String),
    );
    if (r.staticKey.length != 32 || r.ephemeralKey.length != 32) {
      throw PeerDisconnected('bad key length');
    }
    remote = r;
    return r;
  }

  late Handshake _handshake;

  /// Completes the handshake; pairs via PIN if either side lacks trust.
  Future<void> establish(PairingDelegate delegate) async {
    final r = remote!;
    final iTrust = _identity.isTrusted(r.deviceId, r.staticKey);
    _sendPlain({'trusted': iTrust});
    final mode = await _readJson();
    final theyTrust = mode['trusted'] == true;
    final needPairing = !(iTrust && theyTrust);

    var pin = '';
    Completer<void>? pinDialogDone;
    if (needPairing) {
      if (isInitiator) {
        final entered = await delegate
            .enterPin(r)
            .timeout(const Duration(seconds: 90), onTimeout: () => null);
        if (entered == null) throw PeerDisconnected('pairing cancelled');
        pin = entered.trim();
      } else {
        pin = generatePin();
        pinDialogDone = Completer<void>();
        // Don't await: the dialog stays up until CONFIRM succeeds or fails.
        unawaited(
          delegate.showPin(r, pin, pinDialogDone.future).then((accepted) {
            if (!accepted && !_isClosed) close('pairing refused');
          }),
        );
      }
    }

    final keys = await _handshake.derive(
      remoteEphemeral: r.ephemeralKey,
      remoteStatic: r.staticKey,
      pin: pin,
    );
    _cipher = SessionCipher(keys);

    try {
      await _sendControl({'t': 'confirm', 'deviceId': _identity.deviceId});
      final confirm = await _readEncryptedWithTimeout(
        const Duration(seconds: 90),
      );
      if (confirm.$1 != MsgType.control ||
          jsonDecode(utf8.decode(confirm.$2))['t'] != 'confirm') {
        throw PeerDisconnected('unexpected message during confirm');
      }
    } on SecretBoxAuthenticationError {
      pinDialogDone?.complete();
      throw PeerDisconnected(
        needPairing ? 'wrong PIN' : 'key mismatch (re-pair required)',
      );
    } catch (_) {
      pinDialogDone?.complete();
      rethrow;
    }
    pinDialogDone?.complete();

    if (needPairing) {
      await _identity.trust(
        TrustedPeer(deviceId: r.deviceId, name: r.name, publicKey: r.staticKey),
      );
      _pairedThisSession = true;
    }
    unawaited(_readLoop());
  }

  Future<void> send(ClipItem item) async {
    final c = _cipher;
    if (c == null || _isClosed) return;
    final type = item.kind == ClipKind.text ? MsgType.text : MsgType.imagePng;
    final body = await c.seal(type, item.bytes);
    _socket.add(encodeFrame(body));
    await _socket.flush();
  }

  Future<void> ping() => _sendControl({'t': 'ping'});

  Future<void> close([String reason = 'closed']) async {
    if (_isClosed) return;
    _isClosed = true;
    // destroy() tears down both directions immediately; a graceful close()
    // can hang when the peer has already dropped us mid-handshake.
    _socket.destroy();
    unawaited(_frames.cancel());
    // Not awaited: close() only completes once a listener drains the done
    // event, and a connection that failed pairing never had one.
    if (!_items.isClosed) unawaited(_items.close());
    if (!_closed.isCompleted) _closed.complete(reason);
  }

  // ---- internals ----

  void _sendPlain(Map<String, dynamic> j) {
    _socket.add(encodeFrame(utf8.encode(jsonEncode(j))));
  }

  Future<void> _sendControl(Map<String, dynamic> j) async {
    final body = await _cipher!.seal(
      MsgType.control,
      utf8.encode(jsonEncode(j)),
    );
    _socket.add(encodeFrame(body));
    await _socket.flush();
  }

  Future<Map<String, dynamic>> _readJson() async {
    final f = await _nextFrame(const Duration(seconds: 10));
    if (f.length > 4096) throw PeerDisconnected('handshake frame too large');
    return jsonDecode(utf8.decode(f)) as Map<String, dynamic>;
  }

  Future<Uint8List> _nextFrame(Duration timeout) async {
    try {
      if (!await _frames.hasNext.timeout(timeout)) {
        throw PeerDisconnected('connection closed');
      }
      return await _frames.next;
    } on TimeoutException {
      throw PeerDisconnected('timed out');
    }
  }

  Future<(int, Uint8List)> _readEncryptedWithTimeout(Duration t) async {
    final f = await _nextFrame(t);
    return _cipher!.open(f);
  }

  Future<void> _readLoop() async {
    try {
      while (!_isClosed) {
        if (!await _frames.hasNext) break;
        final f = await _frames.next;
        final (type, payload) = await _cipher!.open(f);
        switch (type) {
          case MsgType.text:
            _items.add(
              ClipItem.text(
                utf8.decode(payload),
                sourceDeviceId: remote!.deviceId,
              ),
            );
          case MsgType.imagePng:
            _items.add(
              ClipItem.imagePng(payload, sourceDeviceId: remote!.deviceId),
            );
          case MsgType.control:
            break; // ping etc.
        }
      }
      await close('connection closed');
    } catch (e) {
      await close(
        e is SecretBoxAuthenticationError
            ? 'authentication failed'
            : e.toString(),
      );
    }
  }
}

/// Minimal pull-based wrapper over a stream (avoids depending on package:async).
class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    _sub = stream.listen(
      (e) => _deliver(_Item(value: e)),
      onError: (Object e, StackTrace st) =>
          _deliver(_Item(error: e, stack: st)),
      onDone: () => _deliver(_Item(done: true)),
    );
  }

  late final StreamSubscription<T> _sub;
  final List<_Item<T>> _buffer = [];
  final List<Completer<void>> _waiters = [];
  bool _done = false;

  void _deliver(_Item<T> item) {
    if (item.done) _done = true;
    _buffer.add(item);
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<bool> get hasNext async {
    while (_buffer.isEmpty) {
      if (_done) return false;
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    return !_buffer.first.done;
  }

  Future<T> get next async {
    if (!await hasNext) throw StateError('no more elements');
    final item = _buffer.removeAt(0);
    if (item.error != null) {
      Error.throwWithStackTrace(item.error!, item.stack ?? StackTrace.current);
    }
    return item.value as T;
  }

  Future<void> cancel() => _sub.cancel();
}

class _Item<T> {
  _Item({this.value, this.error, this.stack, this.done = false});
  final T? value;
  final Object? error;
  final StackTrace? stack;
  final bool done;
}
