import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

const String kServiceType = '_clipsync._tcp';

/// A ClipSync instance seen on the LAN via mDNS.
class DiscoveredPeer {
  DiscoveredPeer({
    required this.deviceId,
    required this.name,
    required this.addresses,
    required this.port,
  });
  final String deviceId;
  final String name;
  final List<String> addresses;
  final int port;

  /// Prefer IPv4 for dialing.
  String? get bestAddress {
    for (final a in addresses) {
      if (!a.contains(':')) return a;
    }
    return addresses.isEmpty ? null : addresses.first;
  }
}

/// Advertises this device and discovers other instances with Bonjour/mDNS.
class Discovery extends ChangeNotifier {
  Discovery({required this.deviceId, required this.deviceName});

  final String deviceId;
  final String deviceName;

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription? _sub;

  final Map<String, DiscoveredPeer> _peers = {}; // by deviceId
  final _found = StreamController<DiscoveredPeer>.broadcast();
  final _lost = StreamController<String>.broadcast();

  List<DiscoveredPeer> get peers => _peers.values.toList();
  Stream<DiscoveredPeer> get onFound => _found.stream;
  Stream<String> get onLost => _lost.stream;
  String? lastError;

  Future<void> start(int port) async {
    await stop();
    try {
      final service = BonsoirService(
        // Service names must be unique per host; append a short id suffix.
        name:
            'ClipSync ${deviceName.length > 40 ? deviceName.substring(0, 40) : deviceName} ${deviceId.substring(0, 6)}',
        type: kServiceType,
        port: port,
        attributes: {'id': deviceId, 'name': deviceName},
      );
      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.initialize();
      await _broadcast!.start();

      final d = _discovery = BonsoirDiscovery(type: kServiceType);
      await d.initialize();
      _sub = d.eventStream!.listen(
        _onEvent,
        onError: (Object e) {
          lastError = e.toString();
          notifyListeners();
        },
      );
      await d.start();
      lastError = null;
    } catch (e) {
      lastError = 'mDNS unavailable: $e';
    }
    notifyListeners();
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    debugPrint('[mdns] ${event.runtimeType} ${event.service?.name ?? ''}');
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        // Resolve to obtain host addresses; result arrives as a Resolved event.
        unawaited(service.resolve(_discovery!.serviceResolver));
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
      case BonsoirDiscoveryServiceUpdatedEvent(:final service):
        _upsert(service);
      case BonsoirDiscoveryServiceLostEvent(:final service):
        final id = service.attributes['id'];
        if (id != null && _peers.remove(id) != null) {
          _lost.add(id);
          notifyListeners();
        }
      default:
        break;
    }
  }

  void _upsert(BonsoirService s) {
    final id = s.attributes['id'];
    if (id == null || id == deviceId) return; // ignore ourselves / malformed
    if (s.hostAddresses.isEmpty) return;
    final p = DiscoveredPeer(
      deviceId: id,
      name: s.attributes['name'] ?? s.name,
      addresses: s.hostAddresses,
      port: s.port,
    );
    _peers[id] = p;
    _found.add(p);
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _discovery?.stop();
    } catch (_) {}
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _discovery = null;
    _broadcast = null;
  }

  @override
  void dispose() {
    stop();
    _found.close();
    _lost.close();
    super.dispose();
  }
}
