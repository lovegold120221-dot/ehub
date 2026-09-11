import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:onnxruntime/onnxruntime.dart' as ort;
import 'supertonic_preprocess.dart';

/// On-device Supertonic 3 inference (EburonVoix-3), ported from the official
/// Supertone Python SDK (`supertonic` 1.3.1, `core.py`):
/// text → duration predictor + text encoder → 5 Euler steps of the vector
/// estimator → Vocos vocoder → 44.1 kHz waveform.
///
/// Runs through the `onnxruntime` FFI plugin (`runAsync` executes in a
/// background isolate). Sessions are ~400 MB — load lazily, once.
class SupertonicEngine {
  final String modelDir;
  late final int sampleRate;
  late final int _baseChunkSize;
  late final int _chunkCompress;
  late final int _latentDim;

  late final List<int> _indexer;
  late final ort.OrtSession _dp;
  late final ort.OrtSession _textEnc;
  late final ort.OrtSession _vectorEst;
  late final ort.OrtSession _vocoder;
  final _random = Random();

  SupertonicEngine._(this.modelDir);

  static Future<SupertonicEngine> load(String modelDir,
      {int? intraThreads}) async {
    final engine = SupertonicEngine._(modelDir);
    final cfg = json.decode(
        await File('$modelDir/onnx/tts.json').readAsString()) as Map;
    engine.sampleRate = (cfg['ae'] as Map)['sample_rate'] as int;
    engine._baseChunkSize = (cfg['ae'] as Map)['base_chunk_size'] as int;
    engine._chunkCompress =
        (cfg['ttl'] as Map)['chunk_compress_factor'] as int;
    engine._latentDim = (cfg['ttl'] as Map)['latent_dim'] as int;
    engine._indexer = (json.decode(await File('$modelDir/onnx/unicode_indexer.json')
            .readAsString()) as List)
        .map((e) => e as int)
        .toList();

    final options = ort.OrtSessionOptions();
    if (intraThreads != null && intraThreads > 0) {
      options.setIntraOpNumThreads(intraThreads);
    }
    // Session creation memory-maps ~400 MB of graphs: do it in background
    // isolates so the UI thread never blocks (ANR on phones). Each isolate
    // hands back the native session address, wrapped below.
    Future<ort.OrtSession> open(String name) async {
      final address = await Isolate.run(
          () => _openSession(('$modelDir/onnx/$name', intraThreads)));
      return ort.OrtSession.fromAddress(address);
    }

    engine._dp = await open('duration_predictor.onnx');
    print('[Supertonic] duration predictor loaded');
    engine._textEnc = await open('text_encoder.onnx');
    print('[Supertonic] text encoder loaded');
    engine._vectorEst = await open('vector_estimator.onnx');
    print('[Supertonic] vector estimator loaded');
    engine._vocoder = await open('vocoder.onnx');
    print('[Supertonic] vocoder loaded');
    return engine;
  }

  void dispose() {
    _dp.release();
    _textEnc.release();
    _vectorEst.release();
    _vocoder.release();
  }

  /// Loads a voice style (`voice_styles/<name>.json`) → record with
  /// float32 `ttl`/`dp` vectors and their shapes.
  static Future<SupertonicStyle> loadStyle(
      String modelDir, String name) async {
    final jsonMap = json.decode(await File('$modelDir/voice_styles/$name.json')
        .readAsString()) as Map;
    Float32List vec(Map m) {
      final dims = (m['dims'] as List).map((e) => e as int).toList();
      final n = dims.fold<int>(1, (a, b) => a * b);
      // NB: style data is nested (e.g. dims [1, 50, 256]) — flatten it.
      // Assuming a flat list throws
      // "List<dynamic> is not a subtype of num".
      final flat = <double>[];
      void walk(dynamic v) {
        if (v is List) {
          for (final e in v) {
            walk(e);
          }
        } else {
          flat.add((v as num).toDouble());
        }
      }

      walk(m['data']);
      final data = Float32List(n);
      for (var i = 0; i < n && i < flat.length; i++) {
        data[i] = flat[i];
      }
      return data;
    }

    List<int> dims(Map m) =>
        (m['dims'] as List).map((e) => e as int).toList();
    final ttl = jsonMap['style_ttl'] as Map;
    final dp = jsonMap['style_dp'] as Map;
    return SupertonicStyle(
      ttl: vec(ttl),
      ttlShape: dims(ttl),
      dp: vec(dp),
      dpShape: dims(dp),
    );
  }

  /// Full synthesis: returns mono samples at [sampleRate].
  Future<Float32List> synthesize(
    String text, {
    required SupertonicStyle style,
    required String lang,
    double speed = 1.0,
    int steps = 5,
  }) async {
    final runOptions = ort.OrtRunOptions();
    try {
      // 1. Text → ids + mask
      final preprocessed = SupertonicPreprocess.preprocess(text, lang);
      final ids = SupertonicPreprocess.toIds(preprocessed, _indexer);
      final t = ids.length;
      final textIds = ort.OrtValueTensor.createTensorWithDataList(ids, [1, t]);
      final textMask = ort.OrtValueTensor.createTensorWithDataList(
          Float32List.fromList(List<double>.filled(t, 1.0)), [1, 1, t]);

      // 2. Durations
      final dpOut = await _dp.runAsync(runOptions, {
        'text_ids': textIds,
        'style_dp': ort.OrtValueTensor.createTensorWithDataList(
            style.dp, style.dpShape),
        'text_mask': textMask,
      });
      final durations = _flattenFloat(dpOut!.first!.value).map((d) => d / speed).toList();

      // 3. Text embeddings
      final encOut = await _textEnc.runAsync(runOptions, {
        'text_ids': textIds,
        'style_ttl': ort.OrtValueTensor.createTensorWithDataList(
            style.ttl, style.ttlShape),
        'text_mask': textMask,
      });
      final textEmb = _flattenFloat(encOut!.first!.value);
      final textEmbShape = _shapeOf(encOut.first! as ort.OrtValueTensor);

      // 4. Noisy latent + mask
      final wavLenMax = (durations.reduce(max) * sampleRate).ceil();
      final chunk = _baseChunkSize * _chunkCompress;
      final latentLen = ((wavLenMax + chunk - 1) / chunk).ceil();
      final latentDim = _latentDim * _chunkCompress;
      var xt = _randn(latentLen * latentDim);
      final latentMask = _latentMask(durations, latentLen);

      final styleTtl = ort.OrtValueTensor.createTensorWithDataList(
          style.ttl, style.ttlShape);
      final textEmbT = ort.OrtValueTensor.createTensorWithDataList(
          textEmb, textEmbShape);
      final maskT = ort.OrtValueTensor.createTensorWithDataList(
          latentMask, [1, 1, latentLen]);
      final totalStepT = ort.OrtValueTensor.createTensorWithDataList(
          Float32List.fromList([steps.toDouble()]), [1]);

      for (var step = 0; step < steps; step++) {
        final stepT = ort.OrtValueTensor.createTensorWithDataList(
            Float32List.fromList([step.toDouble()]), [1]);
        final out = await _vectorEst.runAsync(runOptions, {
          'noisy_latent': ort.OrtValueTensor.createTensorWithDataList(
              xt, [1, latentDim, latentLen]),
          'text_emb': textEmbT,
          'style_ttl': styleTtl,
          'text_mask': textMask,
          'latent_mask': maskT,
          'current_step': stepT,
          'total_step': totalStepT,
        });
        xt = _flattenFloat(out!.first!.value);
        stepT.release();
      }

      // 5. Vocoder → waveform
      final wavOut = await _vocoder.runAsync(runOptions, {
        'latent': ort.OrtValueTensor.createTensorWithDataList(
            xt, [1, latentDim, latentLen]),
      });
      return _flattenFloat(wavOut!.first!.value);
    } finally {
      runOptions.release();
    }
  }

  // ── math helpers (mirror core.py) ──

  Float32List _randn(int n) {
    final out = Float32List(n);
    for (var i = 0; i < n; i += 2) {
      final u1 = max(_random.nextDouble(), 1e-12);
      final u2 = _random.nextDouble();
      final r = sqrt(-2.0 * log(u1));
      out[i] = r * cos(2 * pi * u2);
      if (i + 1 < n) out[i + 1] = r * sin(2 * pi * u2);
    }
    return out;
  }

  Float32List _latentMask(List<double> durations, int latentLen) {
    final chunk = _baseChunkSize * _chunkCompress;
    final wavLens = durations.map((d) => (d * sampleRate).floor()).toList();
    final latentLens =
        wavLens.map((w) => ((w + chunk - 1) / chunk).floor()).toList();
    final maxLen = latentLens.reduce(max).clamp(1, latentLen);
    final mask = Float32List(latentLen);
    for (var i = 0; i < maxLen; i++) {
      mask[i] = 1.0;
    }
    return mask;
  }

  static Float32List _flattenFloat(dynamic value) {
    final flat = <double>[];
    void walk(dynamic v) {
      if (v is List) {
        for (final e in v) {
          walk(e);
        }
      } else {
        flat.add((v as num).toDouble());
      }
    }

    walk(value);
    return Float32List.fromList(flat);
  }

  static List<int> _shapeOf(ort.OrtValueTensor tensor) {
    final info = tensor.value;
    return _inferShape(info);
  }

  static List<int> _inferShape(dynamic value) {
    final shape = <int>[];
    var v = value;
    while (v is List) {
      shape.add(v.length);
      v = v.isEmpty ? null : v.first;
    }
    return shape;
  }

  /// Blends voice styles with normalized weights (lerp). Foundation for an
  /// emotion bank: `speaker + warm*0.25 + concerned*0.1`, etc. Emotion
  /// preset embeddings still need Flemish reference recordings to train —
  /// until then the app uses single preset styles (F1–M5).
  static Float32List blendStyles(
      List<Float32List> styles, List<double> weights) {
    assert(styles.length == weights.length && styles.isNotEmpty);
    final n = styles.first.length;
    assert(styles.every((s) => s.length == n));
    final total = weights.fold<double>(0, (a, b) => a + b);
    final out = Float32List(n);
    for (var i = 0; i < styles.length; i++) {
      final w = (total == 0 ? 1.0 / styles.length : weights[i] / total);
      final s = styles[i];
      for (var j = 0; j < n; j++) {
        out[j] += s[j] * w;
      }
    }
    return out;
  }
}

/// Opens one ONNX session in a background isolate and returns its native
/// address. Must stay top-level for [Isolate.run].
int _openSession((String, int?) args) {
  final (path, threads) = args;
  final options = ort.OrtSessionOptions();
  if (threads != null && threads > 0) {
    options.setIntraOpNumThreads(threads);
  }
  final session = ort.OrtSession.fromFile(File(path), options);
  options.release();
  return session.address;
}

class SupertonicStyle {  final Float32List ttl;
  final List<int> ttlShape;
  final Float32List dp;
  final List<int> dpShape;

  const SupertonicStyle({
    required this.ttl,
    required this.ttlShape,
    required this.dp,
    required this.dpShape,
  });
}
