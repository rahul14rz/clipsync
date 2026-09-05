import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/identity.dart';
import '../core/models.dart';
import '../core/settings.dart';
import 'discovery.dart';
import 'peer_connection.dart';

class _Peer {
  _Peer(this.deviceId);
  final String deviceId;
  String name = 'Unknown';
  DiscoveredPeer? discovered;
  PeerConnection? conn;
  PeerStatus status = PeerStatus.offline;
  String? lastError;
  Timer? retry;
  bool dialing = false;
}

/// Owns the listening socket, dials discovered peers, and hands live
/// connections to the sync engine. One connection per remote device.
class PeerManager extends ChangeNotifier {
  PeerManager({
    required this.identity,
    required this.settings,
    required this.pairingDelegate,
  });

  final Identity identity;
  final SettingsStore settings;
  final PairingDelegate pairingDelegate;

  ServerSocket? _server;
  Discovery? _discovery;
  final Map<String, _Peer> _peers = {};
  final _incoming = StreamController<ClipItem>.broadcast();
  final _events = StreamController<String>.broadcast();

  /// Clip items from any authenticated peer.
  Stream<ClipItem> get incoming => _incoming.stream;

  /// Human-readable status events for the UI log.
  Stream<String> get events => _events.stream;

  int get port => _server?.port ?? 0;
  Discovery? get discovery => _discovery;

  List<PeerInfo> get peers =>
      _peers.values
          .map(
            (p) => PeerInfo(
              deviceId: p.deviceId,
              name: p.name,
              status: p.status,
              trusted: identity.trustedPeer(p.deviceId) != null,
              address: p.discovered?.bestAddress ?? p.conn?.remoteAddress,
              port: p.discovered?.port,
              lastError: p.lastError,
            ),
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  int get connectedCount =>
      _peers.values.where((p) => p.status == PeerStatus.connected).length;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_onAccept, onError: (Object e) => _log('server error: $e'));
    // Show trusted peers even before discovery finds them.
    for (final t in identity.trustedPeers) {
      _peer(t.deviceId).name = t.name;
    }
    _discovery = Discovery(
      deviceId: identity.deviceId,
      deviceName: settings.deviceName,
    );
    _discovery!.onFound.listen(_onDiscovered);
    _discovery!.onLost.listen(_onLost);
    _discovery!.addListener(notifyListeners);
    await _discovery!.start(_server!.port);
    _log('listening on port ${_server!.port}');
    notifyListeners();
  }

  Future<void> restartDiscovery() async {
    if (_server == null) return;
    await _discovery?.start(_server!.port);
  }

  /// Manual connect (fallback when mDNS is blocked): dial host:port directly.
  Future<void> connectManual(String host, int port) async {
    await _dial(host, port, peer: null, allowPairing: true);
  }

  /// User asked to pair with a discovered peer.
  Future<void> pair(String deviceId) async {
    final p = _peers[deviceId];
    final d = p?.discovered;
    if (p == null || d == null || d.bestAddress == null) return;
    await _dial(d.bestAddress!, d.port, peer: p, allowPairing: true);
  }

  Future<void> disconnect(String deviceId) async {
    final p = _peers[deviceId];
    p?.retry?.cancel();
    await p?.conn?.close('disconnected by user');
  }

  Future<void> forget(String deviceId) async {
    await disconnect(deviceId);
    await identity.forget(deviceId);
    final p = _peers[deviceId];
    if (p != null && p.discovered == null) _peers.remove(deviceId);
    notifyListeners();
  }

  Future<void> broadcast(ClipItem item) async {
    final conns = _peers.values.where(
      (p) => p.status == PeerStatus.connected && p.conn != null,
    );
    await Future.wait(
      conns.map((p) async {
        try {
          await p.conn!.send(item);
        } catch (e) {
          _log('send to ${p.name} failed: $e');
        }
      }),
    );
  }

  // ---- discovery ----

  _Peer _peer(String id) => _peers.putIfAbsent(id, () => _Peer(id));

  void _onDiscovered(DiscoveredPeer d) {
    final p = _peer(d.deviceId);
    p.discovered = d;
    p.name = d.name;
    if (p.status == PeerStatus.offline) p.status = PeerStatus.discovered;
    notifyListeners();
    _maybeAutoConnect(p);
  }

  void _onLost(String deviceId) {
    final p = _peers[deviceId];
    if (p == null) return;
    p.discovered = null;
    p.retry?.cancel();
    if (p.conn == null) {
      p.status = PeerStatus.offline;
      if (identity.trustedPeer(deviceId) == null) _peers.remove(deviceId);
    }
    notifyListeners();
  }

  /// Trusted peers connect automatically. To avoid both sides dialing at once,
  /// the lower device id dials first; the other side dials only if nothing has
  /// arrived after a grace period.
  void _maybeAutoConnect(_Peer p) {
    if (settings.syncPaused) return;
    if (identity.trustedPeer(p.deviceId) == null) return;
    if (p.conn != null || p.dialing) return;
    final iDialFirst = identity.deviceId.compareTo(p.deviceId) < 0;
    p.retry?.cancel();
    p.retry = Timer(
      iDialFirst ? Duration.zero : const Duration(seconds: 6),
      () {
        final d = p.discovered;
        if (d == null || p.conn != null || d.bestAddress == null) return;
        _dial(d.bestAddress!, d.port, peer: p, allowPairing: false);
      },
    );
  }

  // ---- connections ----

  Future<void> _dial(
    String host,
    int port, {
    required _Peer? peer,
    required bool allowPairing,
  }) async {
    if (peer != null) {
      if (peer.dialing || peer.conn != null) return;
      peer.dialing = true;
      peer.status = PeerStatus.connecting;
      peer.lastError = null;
      notifyListeners();
    }
    PeerConnection? c;
    try {
      c = await PeerConnection.dial(
        host,
        port,
        identity: identity,
        localName: settings.deviceName,
      );
      final hello = await c.hello();
      final p = peer ?? _peer(hello.deviceId);
      if (p.deviceId != hello.deviceId) {
        throw PeerDisconnected('device id mismatch');
      }
      if (!allowPairing &&
          !identity.isTrusted(hello.deviceId, hello.staticKey)) {
        throw PeerDisconnected('not paired');
      }
      await _adopt(p, c, hello);
    } catch (e) {
      await c?.close();
      if (peer != null) {
        peer.lastError = _friendly(e);
        peer.status = peer.discovered != null
            ? PeerStatus.discovered
            : PeerStatus.offline;
        _log('${peer.name}: ${peer.lastError}');
      } else {
        _log('manual connect failed: ${_friendly(e)}');
      }
    } finally {
      peer?.dialing = false;
      notifyListeners();
    }
  }

  Future<void> _onAccept(Socket s) async {
    final c = PeerConnection.accept(
      s,
      identity: identity,
      localName: settings.deviceName,
    );
    try {
      final hello = await c.hello();
      final p = _peer(hello.deviceId);
      await _adopt(p, c, hello);
    } catch (e) {
      _log('incoming connection failed: ${_friendly(e)}');
      await c.close();
    }
    notifyListeners();
  }

  /// Runs the handshake and wires the connection into [p].
  Future<void> _adopt(_Peer p, PeerConnection c, RemoteHello hello) async {
    if (p.conn != null && p.conn!.isOpen) {
      // Duplicate: keep the existing link, drop the new one.
      throw PeerDisconnected('already connected');
    }
    p.name = hello.name;
    p.conn = c;
    final trusted = identity.isTrusted(hello.deviceId, hello.staticKey);
    p.status = trusted ? PeerStatus.connecting : PeerStatus.pairing;
    notifyListeners();

    try {
      await c.establish(pairingDelegate);
    } catch (e) {
      if (identical(p.conn, c)) p.conn = null;
      rethrow;
    }

    p.status = PeerStatus.connected;
    p.lastError = null;
    _log(
      c.pairedThisSession ? 'paired with ${p.name}' : 'connected to ${p.name}',
    );
    notifyListeners();

    c.items.listen(_incoming.add);
    unawaited(
      c.onClose.then((reason) {
        if (!identical(p.conn, c)) return;
        p.conn = null;
        p.status = p.discovered != null
            ? PeerStatus.discovered
            : PeerStatus.offline;
        _log('${p.name} disconnected ($reason)');
        notifyListeners();
        // Reconnect if still visible and trusted.
        if (p.discovered != null) {
          p.retry?.cancel();
          p.retry = Timer(
            const Duration(seconds: 3),
            () => _maybeAutoConnect(p),
          );
        }
      }),
    );
  }

  /// Called when the pause toggle changes.
  void onPauseChanged() {
    if (settings.syncPaused) {
      for (final p in _peers.values) {
        p.retry?.cancel();
        p.conn?.close('sync paused');
      }
    } else {
      for (final p in _peers.values) {
        _maybeAutoConnect(p);
      }
    }
  }

  String _friendly(Object e) {
    if (e is PeerDisconnected) return e.reason;
    if (e is SocketException) return e.osError?.message ?? e.message;
    return e.toString();
  }

  void _log(String s) {
    debugPrint('[peers] $s');
    if (!_events.isClosed) _events.add(s);
  }

  @override
  Future<void> dispose() async {
    for (final p in _peers.values) {
      p.retry?.cancel();
      await p.conn?.close('shutdown');
    }
    await _discovery?.stop();
    await _server?.close();
    await _incoming.close();
    await _events.close();
    super.dispose();
  }
}
