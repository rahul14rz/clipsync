import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/identity.dart';
import '../core/settings.dart';
import '../net/peer_connection.dart';
import '../net/peer_manager.dart';
import '../platform/clipboard_channel.dart';
import '../platform/overlay_channel.dart';
import '../platform/system_channel.dart';
import '../sync/sync_engine.dart';
import '../ui/pairing_dialog.dart';

/// Composition root for the main window engine. Owns every service and the
/// tray/window lifecycle.
class AppState with TrayListener, WindowListener implements PairingDelegate {
  AppState._(this.settings, this.identity);

  static Future<AppState> boot() async {
    final settings = await SettingsStore.load();
    final identity = await Identity.load(settings);
    final app = AppState._(settings, identity);
    await app._init();
    return app;
  }

  final SettingsStore settings;
  final Identity identity;
  final navigatorKey = GlobalKey<NavigatorState>();

  final clipboard = ClipboardChannel();
  final overlay = OverlayChannel();
  final system = SystemChannel();
  late final PeerManager peers;
  late final SyncEngine sync;

  bool _windowVisible = true;

  Future<void> _init() async {
    peers = PeerManager(
      identity: identity,
      settings: settings,
      pairingDelegate: this,
    );
    sync = SyncEngine(
      clipboard: clipboard,
      peers: peers,
      settings: settings,
      overlay: overlay,
      system: system,
    );
    await peers.start();
    sync.start();
    settings.addListener(_onSettingsChanged);
    _lastPaused = settings.syncPaused;
    await _setupWindow();
    await _setupTray();
    await _setupLaunchAtStartup();
  }

  bool _lastPaused = false;
  void _onSettingsChanged() {
    if (_lastPaused != settings.syncPaused) {
      _lastPaused = settings.syncPaused;
      peers.onPauseChanged();
      _refreshTrayMenu();
    }
  }

  // ---- window ----

  Future<void> _setupWindow() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setTitle('ClipSync');
  }

  @override
  void onWindowClose() => hideWindow();

  Future<void> showWindow() async {
    _windowVisible = true;
    if (Platform.isMacOS) await system.setDockVisible(true);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hideWindow() async {
    _windowVisible = false;
    await windowManager.hide();
    if (Platform.isMacOS) await system.setDockVisible(false);
  }

  Future<void> quit() async {
    await trayManager.destroy();
    await peers.dispose();
    exit(0);
  }

  // ---- tray ----

  Future<void> _setupTray() async {
    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/tray/icon.ico' : 'assets/tray/icon_mac.png',
      isTemplate: true,
    );
    await trayManager.setToolTip('ClipSync');
    await _refreshTrayMenu();
  }

  Future<void> _refreshTrayMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Open ClipSync'),
          MenuItem(key: 'send', label: 'Send clipboard now'),
          MenuItem.separator(),
          MenuItem.checkbox(
            key: 'pause',
            label: 'Pause sync',
            checked: settings.syncPaused,
          ),
          MenuItem(key: 'settings', label: 'Settings…'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit ClipSync'),
        ],
      ),
    );
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      _windowVisible ? hideWindow() : showWindow();
    } else {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
      case 'send':
        sync.sendCurrent();
      case 'pause':
        settings.setSyncPaused(!settings.syncPaused);
      case 'settings':
        showWindow().then(
          (_) => navigatorKey.currentState?.pushNamed('/settings'),
        );
      case 'quit':
        quit();
    }
  }

  Future<void> _setupLaunchAtStartup() async {
    try {
      launchAtStartup.setup(
        appName: 'ClipSync',
        appPath: Platform.resolvedExecutable,
      );
    } catch (_) {}
  }

  Future<void> applyLaunchAtLogin(bool enabled) async {
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (e) {
      debugPrint('launch at login failed: $e');
    }
  }

  // ---- pairing UI ----

  @override
  Future<bool> showPin(
    RemoteHello remote,
    String pin,
    Future<void> done,
  ) async {
    await showWindow();
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return true;
    final accepted = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => ShowPinDialog(
        peerName: remote.name,
        fingerprint: Identity.fingerprint(remote.staticKey),
        pin: pin,
        done: done,
      ),
    );
    return accepted ?? true;
  }

  @override
  Future<String?> enterPin(RemoteHello remote) async {
    await showWindow();
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return null;
    return showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => EnterPinDialog(
        peerName: remote.name,
        fingerprint: Identity.fingerprint(remote.staticKey),
      ),
    );
  }
}
