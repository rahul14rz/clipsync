import 'dart:typed_data';

import 'package:clipsync/net/frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips frames split across arbitrary chunks', () {
    final a = Uint8List.fromList([1, 2, 3]);
    final b = Uint8List.fromList(List.generate(1000, (i) => i % 256));
    final wire = Uint8List.fromList([
      ...encodeFrame(a),
      ...encodeFrame(b),
      ...encodeFrame([]),
    ]);

    final dec = FrameDecoder();
    final out = <Uint8List>[];
    // Feed one byte at a time to exercise partial headers/bodies.
    for (var i = 0; i < wire.length; i++) {
      out.addAll(dec.add([wire[i]]));
    }
    expect(out.length, 3);
    expect(out[0], a);
    expect(out[1], b);
    expect(out[2], isEmpty);
  });

  test('rejects oversized frames', () {
    final header = Uint8List(4);
    ByteData.view(header.buffer).setUint32(0, kMaxFrameBytes + 1, Endian.big);
    expect(() => FrameDecoder().add(header), throwsFormatException);
    expect(
      () => encodeFrame(Uint8List(kMaxFrameBytes + 1)),
      throwsArgumentError,
    );
  });
}
