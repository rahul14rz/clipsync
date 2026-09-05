import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/models.dart';

class MainWindow extends StatelessWidget {
  const MainWindow({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ClipSync'),
        actions: [
          IconButton(
            tooltip: 'Send clipboard now',
            icon: const Icon(Icons.send),
            onPressed: app.sync.sendCurrent,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          app.peers,
          app.sync,
          app.settings,
          app.identity,
        ]),
        builder: (context, _) => Column(
          children: [
            _StatusBar(app: app),
            Expanded(child: _PeerList(app: app)),
            _ManualConnect(app: app),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    final paused = s.syncPaused;
    final mdnsErr = app.peers.discovery?.lastError;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              paused ? Icons.pause_circle : Icons.sync,
              color: paused ? Colors.orange : Colors.green,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${s.deviceName} · port ${app.peers.port} · '
                    '${app.peers.connectedCount} connected',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    app.sync.lastEvent,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (mdnsErr != null)
                    Text(
                      mdnsErr,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            Switch(value: !paused, onChanged: (v) => s.setSyncPaused(!v)),
          ],
        ),
      ),
    );
  }
}

class _PeerList extends StatelessWidget {
  const _PeerList({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final peers = app.peers.peers;
    if (peers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_find, size: 48),
            const SizedBox(height: 12),
            const Text('Looking for other ClipSync devices on this network…'),
            const SizedBox(height: 4),
            Text(
              'Open ClipSync on another Mac or PC on the same Wi-Fi.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: app.peers.restartDiscovery,
              icon: const Icon(Icons.refresh),
              label: const Text('Rescan'),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: peers.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _PeerTile(app: app, peer: peers[i]),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.app, required this.peer});
  final AppState app;
  final PeerInfo peer;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (peer.status) {
      PeerStatus.connected => (Icons.check_circle, Colors.green, 'Connected'),
      PeerStatus.connecting => (Icons.sync, Colors.blue, 'Connecting…'),
      PeerStatus.pairing => (Icons.key, Colors.orange, 'Pairing…'),
      PeerStatus.discovered => (
        Icons.radio_button_unchecked,
        Colors.grey,
        peer.trusted ? 'Paired · not connected' : 'Not paired',
      ),
      PeerStatus.offline => (Icons.cloud_off, Colors.grey, 'Offline'),
    };
    final subtitle = [
      label,
      if (peer.address != null) '${peer.address}:${peer.port ?? ''}',
      if (peer.lastError != null) peer.lastError!,
    ].join(' · ');

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(peer.name),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (!peer.trusted && peer.status == PeerStatus.discovered)
            FilledButton.tonal(
              onPressed: () => app.peers.pair(peer.deviceId),
              child: const Text('Pair'),
            ),
          if (peer.trusted && peer.status == PeerStatus.discovered)
            FilledButton.tonal(
              onPressed: () => app.peers.pair(peer.deviceId),
              child: const Text('Connect'),
            ),
          if (peer.status == PeerStatus.connected)
            IconButton(
              tooltip: 'Disconnect',
              icon: const Icon(Icons.link_off),
              onPressed: () => app.peers.disconnect(peer.deviceId),
            ),
          if (peer.trusted)
            IconButton(
              tooltip: 'Forget this device',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => app.peers.forget(peer.deviceId),
            ),
        ],
      ),
    );
  }
}

/// Fallback for networks that block mDNS: dial an IP and port directly.
class _ManualConnect extends StatefulWidget {
  const _ManualConnect({required this.app});
  final AppState app;

  @override
  State<_ManualConnect> createState() => _ManualConnectState();
}

class _ManualConnectState extends State<_ManualConnect> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  bool _expanded = false;

  Future<void> _connect() async {
    final port = int.tryParse(_port.text.trim());
    if (_host.text.trim().isEmpty || port == null) return;
    await widget.app.peers.connectManual(_host.text.trim(), port);
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: const Text('Connect manually (IP address)'),
      dense: true,
      initiallyExpanded: _expanded,
      onExpansionChanged: (v) => setState(() => _expanded = v),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(
                    labelText: 'Host / IP',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _connect(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _connect, child: const Text('Connect')),
            ],
          ),
        ),
      ],
    );
  }
}
