import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/identity.dart';
import '../core/models.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.app});
  final AppState app;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool? _axTrusted;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _name = TextEditingController(text: widget.app.settings.deviceName);
    _refreshAx();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAx();
  }

  Future<void> _refreshAx() async {
    final v = await widget.app.system.isAccessibilityTrusted();
    if (mounted) setState(() => _axTrusted = v);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.app.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _section(context, 'Device'),
            ListTile(
              title: TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Device name',
                  isDense: true,
                ),
                onSubmitted: (v) async {
                  if (v.trim().isEmpty) return;
                  await s.setDeviceName(v.trim());
                  await widget.app.peers.restartDiscovery();
                },
              ),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Shown to other devices. Press Enter to apply.'),
              ),
            ),
            ListTile(
              title: const Text('Device key'),
              subtitle: Text(
                Identity.fingerprint(widget.app.identity.publicKey),
              ),
            ),
            SwitchListTile(
              title: const Text('Launch at login'),
              value: s.launchAtLogin,
              onChanged: (v) async {
                await s.setLaunchAtLogin(v);
                await widget.app.applyLaunchAtLogin(v);
              },
            ),
            SwitchListTile(
              title: const Text('Sync images'),
              subtitle: const Text('Text is always synced'),
              value: s.syncImages,
              onChanged: s.setSyncImages,
            ),

            _section(context, 'Popup notification'),
            SwitchListTile(
              title: const Text('Show popup when content arrives'),
              value: s.showPopup,
              onChanged: s.setShowPopup,
            ),
            ListTile(
              title: const Text('Position'),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _PositionPicker(
                  value: s.popupPosition,
                  onChanged: s.setPopupPosition,
                ),
              ),
            ),
            ListTile(
              title: const Text('Style'),
              trailing: SegmentedButton<PopupStyle>(
                segments: const [
                  ButtonSegment(
                    value: PopupStyle.corner,
                    label: Text('Fade in corner'),
                  ),
                  ButtonSegment(
                    value: PopupStyle.edgeSlide,
                    label: Text('Slide from edge'),
                  ),
                ],
                selected: {s.popupStyle},
                onSelectionChanged: (v) => s.setPopupStyle(v.first),
              ),
            ),
            ListTile(
              title: const Text('Auto-dismiss after'),
              trailing: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 3000, label: Text('3s')),
                  ButtonSegment(value: 5000, label: Text('5s')),
                  ButtonSegment(value: 8000, label: Text('8s')),
                  ButtonSegment(value: 0, label: Text('Never')),
                ],
                selected: {s.dismissMs},
                onSelectionChanged: (v) => s.setDismissMs(v.first),
              ),
            ),
            SwitchListTile(
              title: const Text('Play sound on new content'),
              value: s.soundEnabled,
              onChanged: s.setSoundEnabled,
            ),

            _section(context, 'Click action'),
            RadioGroup<bool>(
              groupValue: s.clickToPaste,
              onChanged: (v) {
                if (v == null) return;
                if (v && _axTrusted == false) return;
                s.setClickToPaste(v);
              },
              child: Column(
                children: [
                  RadioListTile<bool>(
                    title: const Text('Dismiss only'),
                    subtitle: Text(
                      'Content is already on your clipboard; paste with '
                      '${_pasteShortcut()} yourself.',
                    ),
                    value: false,
                  ),
                  RadioListTile<bool>(
                    title: const Text('Paste into the active app'),
                    subtitle: Text(
                      _axTrusted == false
                          ? 'Requires Accessibility permission on macOS.'
                          : 'Clicking the popup sends ${_pasteShortcut()} to the frontmost window.',
                    ),
                    value: true,
                    enabled: _axTrusted ?? true,
                  ),
                ],
              ),
            ),
            if (Platform.isMacOS && _axTrusted == false)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    FilledButton.tonal(
                      onPressed: () async {
                        await widget.app.system.requestAccessibility();
                        await Future.delayed(const Duration(seconds: 1));
                        _refreshAx();
                      },
                      child: const Text('Grant Accessibility access'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _refreshAx,
                      child: const Text('Re-check'),
                    ),
                  ],
                ),
              ),

            _section(context, 'Test'),
            ListTile(
              title: const Text('Preview popup'),
              subtitle: const Text('Shows the notification with sample text'),
              trailing: FilledButton.tonal(
                onPressed: () => widget.app.overlay.show(
                  item: ClipItem.text(
                    'This is what a synced clipboard snippet looks like.',
                  ),
                  fromName: 'Preview',
                  position: s.popupPosition,
                  style: s.popupStyle,
                  dismissMs: s.dismissMs,
                  clickToPaste: s.clickToPaste,
                ),
                child: const Text('Show'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _pasteShortcut() => Platform.isMacOS ? '⌘V' : 'Ctrl+V';

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// A little screen mock with a tappable dot in each corner.
class _PositionPicker extends StatelessWidget {
  const _PositionPicker({required this.value, required this.onChanged});
  final PopupPosition value;
  final ValueChanged<PopupPosition> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget dot(PopupPosition p, Alignment a) => Align(
      alignment: a,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onChanged(p),
          child: Container(
            width: 44,
            height: 22,
            decoration: BoxDecoration(
              color: value == p ? cs.primary : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: cs.outlineVariant),
            ),
          ),
        ),
      ),
    );
    return Container(
      width: 220,
      height: 130,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outline, width: 2),
        color: cs.surface,
      ),
      child: Stack(
        children: [
          dot(PopupPosition.topLeft, Alignment.topLeft),
          dot(PopupPosition.topRight, Alignment.topRight),
          dot(PopupPosition.bottomLeft, Alignment.bottomLeft),
          dot(PopupPosition.bottomRight, Alignment.bottomRight),
          Center(
            child: Text(
              _label(value),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  static String _label(PopupPosition p) => switch (p) {
    PopupPosition.topLeft => 'Top left',
    PopupPosition.topRight => 'Top right',
    PopupPosition.bottomLeft => 'Bottom left',
    PopupPosition.bottomRight => 'Bottom right',
  };
}
