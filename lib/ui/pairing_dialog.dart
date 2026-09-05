import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Responder side: shows the PIN the other device must type.
class ShowPinDialog extends StatefulWidget {
  const ShowPinDialog({
    super.key,
    required this.peerName,
    required this.fingerprint,
    required this.pin,
    required this.done,
  });

  final String peerName;
  final String fingerprint;
  final String pin;

  /// Completes when the connection finished (or failed) pairing.
  final Future<void> done;

  @override
  State<ShowPinDialog> createState() => _ShowPinDialogState();
}

class _ShowPinDialogState extends State<ShowPinDialog> {
  @override
  void initState() {
    super.initState();
    widget.done.then((_) {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final spaced = '${widget.pin.substring(0, 3)} ${widget.pin.substring(3)}';
    return AlertDialog(
      title: Text('Pairing request from ${widget.peerName}'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter this PIN on the other device to pair:'),
            const SizedBox(height: 16),
            SelectableText(
              spaced,
              style: Theme.of(context).textTheme.displayMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 16),
            // Fixed box: QrImageView uses a LayoutBuilder, which cannot report
            // intrinsic sizes inside an AlertDialog's IntrinsicWidth.
            SizedBox.square(
              dimension: 140,
              child: QrImageView(
                data: 'clipsync://pair?pin=${widget.pin}',
                size: 140,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Device key ${widget.fingerprint}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Refuse'),
        ),
      ],
    );
  }
}

/// Initiator side: type the PIN displayed by the other device.
class EnterPinDialog extends StatefulWidget {
  const EnterPinDialog({
    super.key,
    required this.peerName,
    required this.fingerprint,
  });
  final String peerName;
  final String fingerprint;

  @override
  State<EnterPinDialog> createState() => _EnterPinDialogState();
}

class _EnterPinDialogState extends State<EnterPinDialog> {
  final _ctrl = TextEditingController();

  void _submit() {
    final v = _ctrl.text.replaceAll(RegExp(r'\D'), '');
    if (v.length == 6) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Pair with ${widget.peerName}'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Type the 6-digit PIN shown on the other device.'),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 7,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(letterSpacing: 6),
              decoration: const InputDecoration(
                hintText: '000 000',
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Text(
              'Device key ${widget.fingerprint}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Pair')),
      ],
    );
  }
}
