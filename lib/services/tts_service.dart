import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import '../core/constants.dart';
import 'app_log_service.dart';
import 'device_info_service.dart';
import 'download_service.dart';
import 'eburonvoix_lite.dart';
import 'hive_service.dart';
import 'supertonic/flemish_text.dart';
import 'supertonic/supertonic_engine.dart';
import 'supertonic/supertonic_wav.dart';

/// Text-to-speech service: two on-device neural engines, nothing else.
///
/// - EburonVoix-3 (Supertonic 3, custom ORT pipeline): best quality,
///   31 languages, ~400 MB assets, needs a mid-range+ phone.
/// - EburonVoix-Lite (Piper nl_BE-nathalie via sherpa-onnx): tiny (~21 MB),
///   very fast, Flemish-only — the fallback for small phones.
///
/// No system TTS, no cloud. Speech streams sentence-by-sentence from
/// response text; the speaker icon toggles auto-read.
class TtsService extends GetxService {
  HiveService get _hive => Get.find<HiveService>();
  AppLogService get _log => Get.find<AppLogService>();

  final engine = AppConstants.defaultTtsEngine.obs;
  final language = AppConstants.defaultTtsLanguage.obs;
  final neuralVoice = AppConstants.defaultTtsNeuralVoice.obs; // F1..M5
  final neuralState = 'idle'.obs; // idle | loading | ready | error
  final neuralError = ''.obs;
  final liteState = 'idle'.obs; // idle | downloading | loading | ready | error
  final liteError = ''.obs;
  final liteProgress = 0.0.obs;
  final rate = AppConstants.defaultTtsRate.obs; // neural speed 0.7–2.0
  final autoRead = AppConstants.defaultTtsAutoRead.obs;
  final isSpeaking = false.obs;

  // EburonVoix-3 asset download state
  final supertonicDownloading = false.obs;
  final supertonicProgress = 0.0.obs;
  final supertonicPresent = <String>[].obs;

  // Shared WAV playback for both neural engines.
  AudioPlayer? _audioPlayer;
  bool _stopRequested = false;

  // EburonVoix-3 (Supertonic 3, custom ORT engine).
  SupertonicEngine? _neural;
  SupertonicStyle? _neuralStyle;
  String _neuralStyleName = '';

  // EburonVoix-Lite (Piper via sherpa-onnx).
  EburonVoixLite? _lite;

  Future<TtsService> init() async {
    engine.value = _hive.getSetting<String>(AppConstants.keyTtsEngine,
            defaultValue: AppConstants.defaultTtsEngine) ??
        AppConstants.defaultTtsEngine;
    if (engine.value != AppConstants.ttsEngineSupertonic3 &&
        engine.value != AppConstants.ttsEngineLite) {
      engine.value = AppConstants.defaultTtsEngine;
    }
    language.value = _hive.getSetting<String>(AppConstants.keyTtsLanguage,
            defaultValue: AppConstants.defaultTtsLanguage) ??
        AppConstants.defaultTtsLanguage;
    neuralVoice.value = _hive.getSetting<String>(
            AppConstants.keyTtsNeuralVoice,
            defaultValue: AppConstants.defaultTtsNeuralVoice) ??
        AppConstants.defaultTtsNeuralVoice;
    var storedRate = _hive.getSetting<double>(AppConstants.keyTtsRate,
            defaultValue: AppConstants.defaultTtsRate) ??
        AppConstants.defaultTtsRate;
    if (storedRate < AppConstants.minTtsRate) {
      storedRate = AppConstants.defaultTtsRate; // pre-neural 0–1 scale
    }
    rate.value = storedRate.clamp(
        AppConstants.minTtsRate, AppConstants.maxTtsRate);
    autoRead.value = _hive.getSetting<bool>(AppConstants.keyTtsAutoRead,
            defaultValue: AppConstants.defaultTtsAutoRead) ??
        false;
    await refreshSupertonicStatus();
    await refreshLiteStatus();
    if (engine.value == AppConstants.ttsEngineSupertonic3) {
      unawaited(_ensureNeuralEngine().catchError((_) {}));
    } else {
      unawaited(_ensureLiteEngine().catchError((_) {}));
    }
    return this;
  }

  // ── Settings ──

  Future<void> setEngine(String value) async {
    engine.value = value;
    await _hive.setSetting(AppConstants.keyTtsEngine, value);
    await stop();
    if (value == AppConstants.ttsEngineSupertonic3) {
      unawaited(_ensureNeuralEngine().catchError((_) {}));
    } else {
      unawaited(_ensureLiteEngine().catchError((_) {}));
    }
  }

  Future<void> setLanguage(String value) async {
    language.value = value;
    await _hive.setSetting(AppConstants.keyTtsLanguage, value);
  }

  /// Neural voice style (F1–F5, M1–M5). Takes effect on the next utterance.
  Future<void> setNeuralVoice(String value) async {
    neuralVoice.value = value;
    await _hive.setSetting(AppConstants.keyTtsNeuralVoice, value);
    _neuralStyle = null;
  }

  Future<void> setRate(double value) async {
    rate.value = value.clamp(
        AppConstants.minTtsRate, AppConstants.maxTtsRate);
    await _hive.setSetting(AppConstants.keyTtsRate, rate.value);
  }

  Future<void> setAutoRead(bool value) async {
    autoRead.value = value;
    await _hive.setSetting(AppConstants.keyTtsAutoRead, value);
    if (!value) await stop();
  }

  // ── Speak / stop ──

  /// Speaks [text] with the selected engine, replacing anything playing.
  /// Funnel: markdown/think stripping → Flemish normalization (homophone
  /// acronyms, symbols, prosody shaping) → per-engine expression tags.
  Future<void> speak(String text) async {
    final cleaned = FlemishText.normalize(speakableText(text));
    if (cleaned.isEmpty) return;
    if (engine.value == AppConstants.ttsEngineLite) {
      await _speakLite(cleaned);
    } else {
      await _speakNeural(cleaned);
    }
  }

  Future<void> stop() async {
    _stopRequested = true;
    try {
      await _audioPlayer?.stop();
    } catch (_) {}
    isSpeaking.value = false;
  }

  Future<AudioPlayer> _player() async {
    final player = _audioPlayer ??= AudioPlayer();
    await player.setVolume(1.0);
    return player;
  }

  Future<File> _chunkFile() async {
    final modelsDir = await Get.find<DownloadService>().modelsDir;
    return File('$modelsDir/tts_chunk.wav');
  }

  /// Plays one synthesized utterance, streaming-aware: returns when the
  /// chunk finishes (or is stopped). Returns false when stopped.
  Future<bool> _playChunk(
    List<double> wav,
    int sampleRate,
    AudioPlayer player,
    File chunkFile,
  ) async {
    var peak = 0.0;
    for (final s in wav) {
      final a = s.abs();
      if (a > peak) peak = a;
    }
    if (peak < 0.001) return !_stopRequested; // skip silent chunks
    await chunkFile.writeAsBytes(encodeWav16(
        wav is Float32List ? wav : Float32List.fromList(wav), sampleRate),
        flush: true);
    final done = Completer<void>();
    late final StreamSubscription<void> sub;
    sub = player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await player.play(DeviceFileSource(chunkFile.path));
      await done.future.timeout(
        Duration(seconds: (wav.length / sampleRate).ceil() + 15),
        onTimeout: () {},
      );
    } finally {
      await sub.cancel();
    }
    return !_stopRequested;
  }

  /// Test the current engine: Flemish sample for nl, English otherwise.
  Future<void> testVoice() async {
    if (language.value == 'nl') {
      await speak('Hallo! Ik ben Eburon, je Vlaamse assistent. '
          'Ik lees alles voor met een zachte G.');
    } else {
      await speak('Hello! This is Eburon reading aloud.');
    }
  }

  // ── EburonVoix-3 (Supertonic 3, custom ORT engine) ──

  /// True once the ONNX sessions are loaded and assets are present.
  bool get isSupertonicUsable =>
      neuralState.value == 'ready' && _neural != null;

  Future<void> _ensureNeuralEngine() async {
    if (neuralState.value == 'ready' && _neural != null) return;
    if (neuralState.value == 'loading') return;
    neuralState.value = 'loading';
    neuralError.value = '';
    try {
      // Auto-install on first use: missing/corrupt assets download now.
      await _ensureNeuralAssets();
      await refreshSupertonicStatus();
      // The four fp32 sessions need ~1.5 GB free; refuse early with a
      // clear message instead of letting Android kill the app.
      double freeGb = 0;
      try {
        final device = Get.find<DeviceInfoService>();
        await device.refreshMemoryInfo();
        freeGb = device.availableRamGB.value;
      } catch (_) {}
      if (freeGb > 0 && freeGb < 1.2) {
        throw 'Only ${freeGb.toStringAsFixed(1)} GB RAM free — EburonVoix-3 needs ~1.5 GB. Use EburonVoix-Lite on this phone.';
      }
      final dir = await _supertonicDir;
      final cores = Platform.numberOfProcessors;
      final threads = cores <= 0 ? null : cores.clamp(2, 4);
      _neural ??= await SupertonicEngine.load(dir, intraThreads: threads);
      neuralState.value = 'ready';
      _log.info('[TTS] EburonVoix-3 neural engine ready.');
    } catch (e) {
      neuralState.value = 'error';
      neuralError.value = '$e';
      _log.error('[TTS] Neural engine failed to load', details: e);
      rethrow;
    }
  }

  Future<SupertonicStyle> _loadNeuralStyle() async {
    final engine = _neural;
    if (engine == null) throw 'Neural engine is not loaded.';
    if (_neuralStyle == null || _neuralStyleName != neuralVoice.value) {
      final dir = await _supertonicDir;
      _neuralStyle = await SupertonicEngine.loadStyle(dir, neuralVoice.value);
      _neuralStyleName = neuralVoice.value;
    }
    return _neuralStyle!;
  }

  /// Chunked neural playback: synthesize sentence-by-sentence and stream
  /// each WAV as it completes.
  Future<void> _speakNeural(String cleaned) async {
    await stop();
    _stopRequested = false;
    try {
      await _ensureNeuralEngine();
    } catch (_) {
      Get.snackbar(
        'EburonVoix-3 not ready',
        neuralError.value.isEmpty
            ? 'Could not start the neural voice.'
            : neuralError.value,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4),
      );
      return;
    }
    final chunks = splitIntoChunks(
        FlemishText.filterTags(cleaned, FlemishText.supertonicExpressionTags));
    if (chunks.isEmpty) return;
    isSpeaking.value = true;
    try {
      final style = await _loadNeuralStyle();
      final player = await _player();
      final chunkFile = await _chunkFile();
      for (var ci = 0; ci < chunks.length; ci++) {
        if (_stopRequested) break;
        final wav = await _neural!.synthesize(
          chunks[ci],
          style: style,
          lang: _neuralLang(),
          speed: rate.value,
        );
        if (_stopRequested) break;
        _log.info('[TTS] neural chunk ${ci + 1}/${chunks.length}: '
            '${wav.length} samples');
        if (!await _playChunk(wav, _neural!.sampleRate, player, chunkFile)) {
          break;
        }
      }
    } catch (e) {
      _log.error('[TTS] Neural synthesis failed', details: e);
      Get.snackbar('Voice error', '$e',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4));
    } finally {
      isSpeaking.value = false;
    }
  }

  /// Supertonic language tag for the current UI language (fallback: en).
  String _neuralLang() {
    const supported = AppConstants.supertonicLanguages;
    return supported.containsKey(language.value) ? language.value : 'en';
  }

  // ── EburonVoix-Lite (Piper nl_BE via sherpa-onnx) ──

  bool get isLiteUsable => liteState.value == 'ready' && _lite != null;

  Future<String> get _liteDir async {
    final base = await Get.find<DownloadService>().modelsDir;
    final dir = Directory('$base/${AppConstants.liteDirName}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> refreshLiteStatus() async {
    try {
      final files = await EburonVoixLiteFiles.locate(await _liteDir);
      if (files == null && liteState.value == 'ready') {
        liteState.value = 'idle';
        _lite?.dispose();
        _lite = null;
      }
    } catch (_) {}
  }

  String get liteStatusText {
    return switch (liteState.value) {
      'downloading' =>
        'Downloading… ${(liteProgress.value * 100).toStringAsFixed(0)}%',
      'loading' => 'Loading Flemish voice…',
      'ready' => 'Flemish voice ready · offline',
      'error' => liteError.value.isEmpty
          ? 'Voice error — tap to retry download'
          : liteError.value,
      _ => 'Flemish voice not downloaded (~21 MB)',
    };
  }

  Future<void> _ensureLiteEngine() async {
    if (liteState.value == 'ready' && _lite != null) return;
    if (liteState.value == 'loading' || liteState.value == 'downloading') {
      return;
    }
    liteState.value = 'loading';
    liteError.value = '';
    try {
      var files = await EburonVoixLiteFiles.locate(await _liteDir);
      files ??= await downloadLiteVoice();
      _lite?.dispose();
      _lite = await EburonVoixLite.load(
        modelPath: files.modelPath,
        tokensPath: files.tokensPath,
        espeakDir: files.espeakDir,
      );
      liteState.value = 'ready';
      _log.info('[TTS] EburonVoix-Lite ready.');
    } catch (e) {
      liteState.value = 'error';
      liteError.value = '$e';
      _log.error('[TTS] Lite engine failed to load', details: e);
      rethrow;
    }
  }

  /// Downloads the Piper nl_BE bundle (+ espeak data if the bundle lacks
  /// it), extracts into `<models>/eburonvoix-lite/`, and returns the
  /// located voice files.
  Future<EburonVoixLiteFiles> downloadLiteVoice() async {
    liteState.value = 'downloading';
    liteError.value = '';
    liteProgress.value = 0.0;
    try {
      final dir = await _liteDir;
      await _downloadAndExtract(
        AppConstants.liteBundleUrl,
        dir,
        0.0,
        0.85,
      );
      var files = await EburonVoixLiteFiles.locate(dir);
      if (files == null || !_hasEspeak(files)) {
        await _downloadAndExtract(
          AppConstants.liteEspeakUrl,
          '$dir/espeak-ng-data',
          0.85,
          1.0,
        );
        files = await EburonVoixLiteFiles.locate(dir);
      }
      final located = files;
      if (located == null || !_hasEspeak(located)) {
        throw 'Voice files incomplete after download. Delete and retry.';
      }
      await refreshLiteStatus();
      return located;
    } catch (e) {
      liteState.value = 'error';
      liteError.value = '$e';
      _log.error('[TTS] Lite voice download failed', details: e);
      rethrow;
    } finally {
      if (liteState.value == 'downloading') liteState.value = 'idle';
    }
  }

  bool _hasEspeak(EburonVoixLiteFiles files) =>
      Directory(files.espeakDir).existsSync();

  Future<void> _downloadAndExtract(
    String url,
    String destDir,
    double from,
    double to,
  ) async {
    final tmpFile =
        File('$destDir/.download-${DateTime.now().millisecondsSinceEpoch}');
    try {
      await Dio().download(
        url,
        tmpFile.path,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            liteProgress.value = from + (to - from) * received / total;
          }
        },
      );
      final bytes = await tmpFile.readAsBytes();
      final tarBytes = BZip2Decoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(tarBytes);
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final out = File('$destDir/${file.name}');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(file.content as List<int>);
      }
      liteProgress.value = to;
    } finally {
      if (await tmpFile.exists()) await tmpFile.delete();
    }
  }

  /// Chunked Lite playback through the shared WAV pipeline.
  Future<void> _speakLite(String cleaned) async {
    await stop();
    _stopRequested = false;
    try {
      await _ensureLiteEngine();
    } catch (_) {
      Get.snackbar(
        'EburonVoix-Lite not ready',
        liteError.value.isEmpty
            ? 'Could not start the Lite voice.'
            : liteError.value,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4),
      );
      return;
    }
    // The Lite voice speaks Dutch; other languages still synthesize but
    // with Dutch phonemization. Expression tags would be read aloud by
    // espeak, so they are stripped (Supertonic-only feature).
    final chunks = splitIntoChunks(FlemishText.filterTags(cleaned, const {}));
    if (chunks.isEmpty) return;
    isSpeaking.value = true;
    try {
      final lite = _lite;
      if (lite == null) throw 'Lite engine is not loaded.';
      final player = await _player();
      final chunkFile = await _chunkFile();
      for (var ci = 0; ci < chunks.length; ci++) {
        if (_stopRequested) break;
        final utterance =
            await Future(() => lite.synthesize(chunks[ci], speed: rate.value));
        if (_stopRequested) break;
        _log.info('[TTS] lite chunk ${ci + 1}/${chunks.length}: '
            '${utterance.samples.length} samples');
        if (!await _playChunk(
            utterance.samples, utterance.sampleRate, player, chunkFile)) {
          break;
        }
      }
    } catch (e) {
      _log.error('[TTS] Lite synthesis failed', details: e);
      Get.snackbar('Voice error', '$e',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4));
    } finally {
      isSpeaking.value = false;
    }
  }

  // ── Chunked text splitting ──

  /// Splits [text] into sentence-aware chunks of at most [maxLen] chars so
  /// long answers stream as continuous speech instead of one giant
  /// utterance. Pure (unit-tested).
  static List<String> splitIntoChunks(String text, [int maxLen = 300]) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return [];
    final sentences = cleaned
        .split(RegExp(r'(?<=[.!?…\n])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final chunks = <String>[];
    final current = StringBuffer();
    void flush() {
      final s = current.toString().trim();
      if (s.isNotEmpty) chunks.add(s);
      current.clear();
    }

    for (final sentence in sentences) {
      if (sentence.length > maxLen) {
        flush();
        chunks.addAll(_hardSplit(sentence, maxLen));
      } else if (current.length + sentence.length + 1 > maxLen) {
        flush();
        current.write(sentence);
      } else {
        if (current.isNotEmpty) current.write(' ');
        current.write(sentence);
      }
    }
    flush();
    return chunks;
  }

  static List<String> _hardSplit(String sentence, int maxLen) {
    final parts = <String>[];
    var rest = sentence;
    while (rest.length > maxLen) {
      var cut = rest.lastIndexOf(RegExp(r'[ ,;:]\s'), maxLen);
      if (cut < maxLen ~/ 3) cut = maxLen;
      parts.add(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trim();
    }
    if (rest.isNotEmpty) parts.add(rest);
    return parts;
  }

  /// Strips reasoning traces and markdown so TTS reads words, not syntax.
  static String speakableText(String text) {
    var out = text
        .replaceAll(RegExp(r'<think>[\s\S]*?</think>'), ' ')
        .replaceAll(RegExp(r'<thought>[\s\S]*?</thought>'), ' ')
        .replaceAll(RegExp(r'<\|[^|]*\|>'), ' ')
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' code block ');
    out = out.replaceAll(RegExp(r'`([^`]*)`'), r'$1');
    out = out.replaceAllMapped(
        RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '');
    out = out.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    out = out.replaceAll(RegExp(r'[*_~]{1,3}'), '');
    out = out.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
    out = out.replaceAll(RegExp(r'^\s*\d+[.)]\s+', multiLine: true), '');
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ── EburonVoix-3 assets (auto-installed, validated) ──

  static const _supertonicDirName = 'supertonic-3';

  /// Every file the neural engine needs: 4 ONNX modules, config, indexer,
  /// and all 10 preset voice styles.
  static List<String> _supertonicWantedFiles() => [
        ...AppConstants.supertonicAssetFiles,
        for (final v in AppConstants.supertonicNeuralVoices)
          'voice_styles/$v.json',
      ];

  /// Minimum sane bytes per asset. Anything smaller is a truncated download,
  /// not a model — the classic "engine won't start" cause.
  static int _supertonicMinBytes(String asset) {
    if (asset.endsWith('vector_estimator.onnx')) return 200 * 1024 * 1024;
    if (asset.endsWith('vocoder.onnx')) return 80 * 1024 * 1024;
    if (asset.endsWith('text_encoder.onnx')) return 30 * 1024 * 1024;
    if (asset.endsWith('duration_predictor.onnx')) return 1024 * 1024;
    if (asset.endsWith('unicode_indexer.json')) return 200 * 1024;
    if (asset.endsWith('.json')) return 1024;
    return 1;
  }

  /// Lists wanted files that are missing or corrupt under [dirPath].
  /// Pure filesystem check (unit-tested).
  static Future<List<String>> supertonicAssetProblems(String dirPath) async {
    final problems = <String>[];
    for (final asset in _supertonicWantedFiles()) {
      final file = File('$dirPath/$asset');
      if (!await file.exists()) {
        problems.add(asset);
        continue;
      }
      try {
        if (await file.length() < _supertonicMinBytes(asset)) {
          problems.add(asset);
          continue;
        }
        if (asset.endsWith('.json')) {
          final decoded = jsonDecode(await file.readAsString());
          if (asset.endsWith('unicode_indexer.json')) {
            if (decoded is! List || decoded.length < 1000) {
              problems.add(asset);
            }
          } else if (decoded is! Map) {
            problems.add(asset);
          }
        }
      } catch (_) {
        problems.add(asset);
      }
    }
    return problems;
  }

  Future<String> get _supertonicDir async {
    final base = await Get.find<DownloadService>().modelsDir;
    final dir = Directory('$base/$_supertonicDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> refreshSupertonicStatus() async {
    try {
      final dir = await _supertonicDir;
      final problems = await supertonicAssetProblems(dir);
      supertonicPresent.value = _supertonicWantedFiles()
          .where((f) => !problems.contains(f))
          .toList();
    } catch (_) {
      supertonicPresent.value = [];
    }
  }

  int get supertonicTotalFiles => _supertonicWantedFiles().length;

  String get supertonicStatusText {
    if (supertonicDownloading.value) {
      return 'Downloading… ${(supertonicProgress.value * 100).toStringAsFixed(0)}% (tap to cancel)';
    }
    final state = switch (neuralState.value) {
      'ready' => 'neural engine ready',
      'loading' => 'loading neural engine…',
      'error' => 'engine error — see below',
      _ => 'neural engine idle',
    };
    return '${supertonicPresent.length}/$supertonicTotalFiles files · $state';
  }

  CancelToken? _supertonicCancel;

  /// Cancels an in-progress voice model download.
  void cancelSupertonicDownload() {
    _supertonicCancel?.cancel('cancelled by user');
  }

  /// Downloads missing/corrupt EburonVoix-3 assets into
  /// `<models>/supertonic-3/` (ignored by the model list). Each file lands
  /// as `.part` first and is validated before replacing the target, so an
  /// interrupted download can never poison the engine. Retries 3×.
  Future<void> downloadSupertonicAssets() async {
    if (supertonicDownloading.value) return;
    supertonicDownloading.value = true;
    supertonicProgress.value = 0.0;
    final cancel = _supertonicCancel = CancelToken();
    try {
      final dir = await _supertonicDir;
      var problems = await supertonicAssetProblems(dir);
      // Drop corrupt finals so they download fresh.
      for (final bad in problems) {
        final target = File('$dir/$bad');
        if (await target.exists()) await target.delete();
      }
      final files = _supertonicWantedFiles();
      final dio = Dio();
      var done = files.length - problems.length;
      supertonicProgress.value = done / files.length;
      for (final asset in problems) {
        if (cancel.isCancelled) break;
        final target = File('$dir/$asset');
        final part = File('${target.path}.part');
        await target.parent.create(recursive: true);
        if (await part.exists()) await part.delete();
        var ok = false;
        for (var attempt = 1; attempt <= 3 && !ok; attempt++) {
          try {
            await dio.download(
              AppConstants.supertonicAssetUrl(asset),
              part.path,
              cancelToken: cancel,
              deleteOnError: true,
              onReceiveProgress: (received, total) {
                if (total > 0) {
                  supertonicProgress.value =
                      (done + received / total) / files.length;
                }
              },
            );
            await part.rename(target.path);
            ok = true;
          } catch (e) {
            if (e is DioException && CancelToken.isCancel(e)) break;
            _log.error(
                '[TTS] asset $asset attempt $attempt/3 failed', details: e);
            if (await part.exists()) await part.delete();
            if (attempt == 3) rethrow;
            await Future.delayed(Duration(seconds: attempt * 2));
          }
        }
        if (!ok) break;
        done++;
        supertonicProgress.value = done / files.length;
      }
      await refreshSupertonicStatus();
      final remaining = await supertonicAssetProblems(dir);
      if (remaining.isEmpty) {
        _log.info('[TTS] EburonVoix-3 assets ready '
            '(${supertonicPresent.length}/$supertonicTotalFiles).');
      } else if (!cancel.isCancelled) {
        throw 'Still missing ${remaining.length} files: ${remaining.take(2).join(', ')}…';
      }
    } catch (e) {
      if (e is! DioException || !CancelToken.isCancel(e)) {
        _log.error('[TTS] Voice model download failed', details: e);
        rethrow;
      }
    } finally {
      _supertonicCancel = null;
      supertonicDownloading.value = false;
      await refreshSupertonicStatus();
    }
  }

  /// Ensures assets exist (auto-installing them on first use), then loads.
  Future<void> _ensureNeuralAssets() async {
    final dir = await _supertonicDir;
    if ((await supertonicAssetProblems(dir)).isNotEmpty) {
      _log.info('[TTS] auto-installing EburonVoix-3 voice model…');
      await downloadSupertonicAssets();
      if ((await supertonicAssetProblems(dir)).isNotEmpty) {
        throw 'Voice model download incomplete. Check connection and retry.';
      }
    }
  }
}
