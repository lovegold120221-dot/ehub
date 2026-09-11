import 'dart:io';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// EburonVoix-Lite: Piper Flemish voice (`nl_BE-nathalie`) through
/// sherpa-onnx's battle-tested VITS runtime. Tiny (~21 MB int8), very fast,
/// fully offline. Created via [EburonVoixLite.load].
class EburonVoixLite {
  final sherpa.OfflineTts _tts;

  EburonVoixLite._(this._tts);

  static bool _bindingsLoaded = false;

  /// Loads the voice from [voiceDir], which must contain the Piper
  /// `*.onnx` model, `tokens.txt`, and an `espeak-ng-data` directory
  /// (see [EburonVoixLiteFiles.locate]).
  static Future<EburonVoixLite> load({
    required String modelPath,
    required String tokensPath,
    required String espeakDir,
    int threads = 2,
  }) async {
    if (!_bindingsLoaded) {
      sherpa.initBindings();
      _bindingsLoaded = true;
    }
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: modelPath,
          tokens: tokensPath,
          dataDir: espeakDir,
        ),
        numThreads: threads,
        debug: false,
      ),
    );
    final tts = await Future(() => sherpa.OfflineTts(config));
    return EburonVoixLite._(tts);
  }

  /// Synthesizes [text] → mono samples. Blocking native call; invoke from
  /// a background context and keep texts sentence-sized.
  Future<LiteUtterance> synthesize(String text, {double speed = 1.0}) async {
    final audio = await Future(
        () => _tts.generate(text: text, sid: 0, speed: speed));
    return LiteUtterance(
        samples: audio.samples, sampleRate: audio.sampleRate);
  }

  void dispose() => _tts.free();
}

class LiteUtterance {
  final List<double> samples;
  final int sampleRate;

  const LiteUtterance({required this.samples, required this.sampleRate});
}

/// Locates the VITS voice files inside an extracted Piper bundle directory.
/// Piper bundles vary (some nest one level deep), so this searches instead
/// of assuming exact paths.
class EburonVoixLiteFiles {
  final String modelPath;
  final String tokensPath;
  final String espeakDir;

  const EburonVoixLiteFiles({
    required this.modelPath,
    required this.tokensPath,
    required this.espeakDir,
  });

  static Future<EburonVoixLiteFiles?> locate(String voiceDir) async {
    final dir = Directory(voiceDir);
    if (!await dir.exists()) return null;
    String? model;
    String? tokens;
    String? espeak;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      final path = entity.path;
      if (entity is File && model == null && path.endsWith('.onnx')) {
        model = path;
      } else if (entity is File &&
          tokens == null &&
          path.endsWith('tokens.txt')) {
        tokens = path;
      } else if (entity is Directory &&
          espeak == null &&
          path.endsWith('espeak-ng-data')) {
        espeak = path;
      }
      if (model != null && tokens != null && espeak != null) break;
    }
    if (model == null || tokens == null || espeak == null) return null;
    return EburonVoixLiteFiles(
        modelPath: model, tokensPath: tokens, espeakDir: espeak);
  }
}
