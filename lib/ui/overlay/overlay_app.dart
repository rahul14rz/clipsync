import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../platform/overlay_channel.dart';

/// Root of the overlay engine. Transparent background; draws a single card
/// that animates in, waits, and animates out.
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const _OverlayHost(),
    );
  }
}

class _OverlayHost extends StatefulWidget {
  const _OverlayHost();

  @override
  State<_OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<_OverlayHost>
    with SingleTickerProviderStateMixin {
  final _channel = OverlayUiChannel();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 200),
  );
  StreamSubscription? _sub;
  Timer? _dismiss;
  Map<String, dynamic>? _payload;
  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    _sub = _channel.shows.listen(_show);
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && _payload != null) {
        _payload = null;
        _channel.dismissed();
        if (mounted) setState(() {});
      }
    });
  }

  void _show(Map<String, dynamic> p) {
    _dismiss?.cancel();
    setState(() => _payload = p);
    _anim.forward(from: _anim.value > 0 ? _anim.value : 0);
    _armTimer();
  }

  void _armTimer() {
    _dismiss?.cancel();
    final ms = (_payload?['dismissMs'] as num?)?.toInt() ?? 5000;
    if (ms <= 0) return;
    _dismiss = Timer(Duration(milliseconds: ms), () {
      if (_hovering) {
        _armTimer(); // keep it while the pointer rests on it
      } else {
        _anim.reverse();
      }
    });
  }

  void _onTap() {
    _dismiss?.cancel();
    _channel.clicked();
    _anim.reverse();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _dismiss?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    return Scaffold(
      backgroundColor: Colors.transparent,
      // The card must never overflow its fixed native window; clip defensively.
      body: p == null
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: _anim,
              builder: (context, child) {
                final t = Curves.easeOutCubic.transform(_anim.value);
                final offset = _slideOffset(p, t);
                return Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.translate(offset: offset, child: child),
                );
              },
              child: MouseRegion(
                onEnter: (_) => _hovering = true,
                onExit: (_) => _hovering = false,
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _onTap,
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: _Card(payload: p),
                  ),
                ),
              ),
            ),
    );
  }

  /// Slide direction depends on style and dock position.
  Offset _slideOffset(Map<String, dynamic> p, double t) {
    final style = p['style'] as String? ?? 'corner';
    final pos = p['position'] as String? ?? 'bottomRight';
    final remaining = 1 - t;
    if (style == 'edgeSlide') {
      final fromRight = pos.endsWith('Right');
      return Offset((fromRight ? 1 : -1) * 360 * remaining, 0);
    }
    final fromBottom = pos.startsWith('bottom');
    return Offset(0, (fromBottom ? 1 : -1) * 16 * remaining);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.payload});
  final Map<String, dynamic> payload;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isImage = payload['kind'] == 'image';
    final png = payload['png'] as Uint8List?;
    final text = payload['text'] as String? ?? '';
    final from = payload['from'] as String? ?? 'peer';
    final clickToPaste = payload['clickToPaste'] == true;

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        elevation: 12,
        shadowColor: Colors.black54,
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isImage ? Icons.image_outlined : Icons.content_paste,
                  color: cs.onPrimaryContainer,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Clipboard from $from',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: cs.primary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          clickToPaste ? 'Click to paste' : 'Click to dismiss',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (isImage && png != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          png,
                          height: 84,
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          cacheHeight: 168,
                          gaplessPlayback: true,
                        ),
                      )
                    else
                      Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
