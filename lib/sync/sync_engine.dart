import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/settings.dart';
import '../net/peer_manager.dart';
import '../platform/clipboard_channel.dart';
import '../platform/overlay_channel.dart';
import '../platform/system_channel.dart';

/// Glue between the OS clipboard and the peer mesh.
///
/// Local change → broadcast to peers. Incoming item → write to clipboard,
/// show the overlay, optionally beep. Loop prevention: we remember the hash
/// of whatever we last wrote from a peer and of recent broadcasts, and ignore
/// local change events whose content matches.
class SyncEngine extends ChangeNotifier {
  SyncEngine({
    required this.clipboard,
    required this.peers,
    required this.settings,
    required this.overlay,
    required this.system,
  });

  final ClipboardChannel clipboard;
  final PeerManager peers;
  final SettingsStore settings;
  final OverlayChannel overlay;
  final SystemChannel system;

  final RecentHashes _recentlySent = RecentHashes(8);
  String? _lastAppliedHash;
  int _pendingSelfChanges = 0;
  bool _reading = false;

  /// Last activity line for the UI ("Sent text to X").
  String lastEvent = 'Idle';
  DateTime? lastEventAt;
  int sentCount = 0;
  int receivedCount = 0;

  StreamSubscription? _clipSub;
  StreamSubscription? _peerSub;
  StreamSubscription? _clickSub;

  void start() {
    _clipSub = clipboard.changes.listen((_) => _onLocalChange());
    _peerSub = peers.incoming.listen(_onIncoming);
    _clickSub = overlay.clicks.listen((_) => _onOverlayClick());
  }

  Future<void> _onLocalChange() async {
    if (settings.syncPaused) return;
    if (_pendingSelfChanges > 0) {
      // Change caused by our own write; still verify by hash below in case a
      // real copy raced with it.
      _pendingSelfChanges--;
    }
    if (_reading) return;
    _reading = true;
    try {
      final item = await clipboard.read();
      if (item == null) return;
      if (item.kind == ClipKind.image && !settings.syncImages) return;
      if (item.sha256 == _lastAppliedHash ||
          _recentlySent.contains(item.sha256)) {
        return; // echo of something we set or already sent
      }
      if (peers.connectedCount == 0) return;
      _recentlySent.add(item.sha256);
      await peers.broadcast(item);
      sentCount++;
      _setEvent('Sent ${_describe(item)} to ${peers.connectedCount} peer(s)');
    } catch (e) {
      debugPrint('[sync] local change failed: $e');
    } finally {
      _reading = false;
    }
  }

  Future<void> _onIncoming(ClipItem item) async {
    if (settings.syncPaused) return;
    if (item.kind == ClipKind.image && !settings.syncImages) return;
    if (item.sha256 == _lastAppliedHash) return; // duplicate delivery
    _lastAppliedHash = item.sha256;
    _recentlySent.add(item.sha256); // never rebroadcast what we received
    _pendingSelfChanges++;
    try {
      await clipboard.write(item);
    } catch (e) {
      debugPrint('[sync] clipboard write failed: $e');
      _pendingSelfChanges = 0;
      return;
    }
    receivedCount++;
    final from = _peerName(item.sourceDeviceId);
    _setEvent('Received ${_describe(item)} from $from');

    if (settings.soundEnabled) unawaited(system.beep());
    if (settings.showPopup) {
      unawaited(
        overlay.show(
          item: item,
          fromName: from,
          position: settings.popupPosition,
          style: settings.popupStyle,
          dismissMs: settings.dismissMs,
          clickToPaste: settings.clickToPaste,
        ),
      );
    }
  }

  Future<void> _onOverlayClick() async {
    if (!settings.clickToPaste) return;
    final ok = await system.simulatePaste();
    if (!ok) _setEvent('Paste failed: Accessibility permission missing?');
  }

  /// Sends whatever is on the clipboard right now (manual "Send now").
  Future<void> sendCurrent() async {
    final item = await clipboard.read();
    if (item == null) {
      _setEvent('Clipboard is empty or unsupported');
      return;
    }
    _recentlySent.add(item.sha256);
    await peers.broadcast(item);
    sentCount++;
    _setEvent('Sent ${_describe(item)} to ${peers.connectedCount} peer(s)');
  }

  String _peerName(String id) {
    for (final p in peers.peers) {
      if (p.deviceId == id) return p.name;
    }
    return 'peer';
  }

  String _describe(ClipItem i) =>
      i.kind == ClipKind.image ? i.preview() : 'text (${i.bytes.length} bytes)';

  void _setEvent(String s) {
    lastEvent = s;
    lastEventAt = DateTime.now();
    notifyListeners();
  }

  @override
  void dispose() {
    _clipSub?.cancel();
    _peerSub?.cancel();
    _clickSub?.cancel();
    super.dispose();
  }
}
