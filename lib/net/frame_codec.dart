import 'dart:async';
import 'dart:typed_data';

/// Maximum accepted frame body (protects memory: images can be big, but not unbounded).
const int kMaxFrameBytes = 32 * 1024 * 1024;

/// Encodes a body as `u32 big-endian length || body`.
Uint8List encodeFrame(List<int> body) {
  if (body.length > kMaxFrameBytes) {
    throw ArgumentError('frame too large: ${body.length}');
  }
  final out = Uint8List(4 + body.length);
  ByteData.view(out.buffer).setUint32(0, body.length, Endian.big);
  out.setRange(4, out.length, body);
  return out;
}

/// Reassembles length-prefixed frames from an arbitrary byte stream.
class FrameDecoder {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List? _pending; // flattened buffer with leftover bytes

  /// Feed bytes; returns every complete frame body found so far.
  /// Throws [FormatException] if a frame exceeds [kMaxFrameBytes].
  List<Uint8List> add(List<int> chunk) {
    final frames = <Uint8List>[];
    if (_pending != null && _pending!.isNotEmpty) {
      _buf.add(_pending!);
      _pending = null;
    }
    _buf.add(chunk);
    var data = _buf.takeBytes();
    var offset = 0;
    while (data.length - offset >= 4) {
      final len = ByteData.sublistView(
        data,
        offset,
        offset + 4,
      ).getUint32(0, Endian.big);
      if (len > kMaxFrameBytes) {
        throw const FormatException('frame exceeds maximum size');
      }
      if (data.length - offset - 4 < len) break;
      frames.add(Uint8List.sublistView(data, offset + 4, offset + 4 + len));
      offset += 4 + len;
    }
    _pending = offset == 0 ? data : Uint8List.sublistView(data, offset);
    // Copy leftover so it doesn't pin a huge parent buffer.
    if (_pending != null) _pending = Uint8List.fromList(_pending!);
    return frames;
  }
}

/// Stream transformer form of [FrameDecoder].
StreamTransformer<Uint8List, Uint8List> frameTransformer() {
  final decoder = FrameDecoder();
  return StreamTransformer.fromHandlers(
    handleData: (chunk, sink) {
      try {
        for (final f in decoder.add(chunk)) {
          sink.add(f);
        }
      } catch (e, st) {
        sink.addError(e, st);
      }
    },
  );
}
