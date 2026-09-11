import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/supertonic/supertonic_engine.dart';

void main() {
  // Manual bring-up proof: needs a host ORT dylib + ~400 MB of model files
  // at /tmp/st3, so it stays skipped in normal runs. Proven passing on
  // 2026-09-09 (46-char Dutch → 4.6 s audio, peak 0.37, 2.8% zeros).
  test(
    'full neural synthesis on host (manual)',
    () async {
      final engine =
          await SupertonicEngine.load('/tmp/st3', intraThreads: 4);
      expect(engine.sampleRate, 44100);
      final style = await SupertonicEngine.loadStyle('/tmp/st3', 'F1');
      print('style ttl=${style.ttlShape} dp=${style.dpShape}');
      const text = 'Hallo! Ik ben Eburon, je Vlaamse assistent.';
      final wav = await engine.synthesize(text, style: style, lang: 'nl');
      double max = 0, sum = 0;
      var zeros = 0;
      for (final s in wav) {
        final a = s.abs();
        if (a > max) max = a;
        sum += a;
        if (a < 1e-6) zeros++;
      }
      print('samples=${wav.length} secs=${wav.length / engine.sampleRate} '
          'max=$max mean=${sum / wav.length} zeroRatio=${zeros / wav.length}');
      expect(wav.isNotEmpty, isTrue);
      expect(max, greaterThan(0.05));
      engine.dispose();
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: 'needs host libonnxruntime + model files at /tmp/st3',
  );
}
