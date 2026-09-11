import 'dart:math';
import 'dart:typed_data';

/// Encodes mono float32 samples as 16-bit PCM WAV bytes for playback.
///
/// Applies short raised-cosine fades (default 15 ms) at both ends: TTS
/// audio plays back sentence-by-sentence, and raw chunk joints otherwise
/// click. Pure (unit-testable).
Uint8List encodeWav16(Float32List samples, int sampleRate,
    {double fadeMs = 15.0}) {
  final faded = Float32List.fromList(samples);
  final fadeN =
      (sampleRate * fadeMs / 1000).round().clamp(0, faded.length ~/ 2);
  for (var i = 0; i < fadeN; i++) {
    final t = 0.5 - 0.5 * cos(i / fadeN * 3.141592653589793);
    faded[i] *= t;
    faded[faded.length - 1 - i] *= t;
  }
  final dataBytes = faded.length * 2;
  final out = ByteData(44 + dataBytes);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < faded.length; i++) {
    final v = (faded[i].clamp(-1.0, 1.0) * 32767).round();
    out.setInt16(44 + i * 2, v, Endian.little);
  }
  return out.buffer.asUint8List();
}
