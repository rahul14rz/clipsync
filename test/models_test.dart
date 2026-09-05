import 'dart:typed_data';

import 'package:clipsync/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same content hashes equal, different content differs', () {
    final a = ClipItem.text('hello');
    final b = ClipItem.text('hello');
    final c = ClipItem.text('hello!');
    expect(a.sha256, b.sha256);
    expect(a.sha256, isNot(c.sha256));
    final img = ClipItem.imagePng(Uint8List.fromList([137, 80, 78, 71]));
    expect(img.kind, ClipKind.image);
    expect(img.preview(), contains('Image'));
  });

  test('preview truncates and collapses whitespace', () {
    final item = ClipItem.text('a\n\n  b ${'x' * 300}');
    final p = item.preview(max: 10);
    expect(p.startsWith('a b '), isTrue);
    expect(p.length, 11); // 10 chars + ellipsis
  });

  test('recent hashes evicts oldest', () {
    final r = RecentHashes(2);
    r.add('a');
    r.add('b');
    r.add('c');
    expect(r.contains('a'), isFalse);
    expect(r.contains('b'), isTrue);
    expect(r.contains('c'), isTrue);
  });
}
