import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../core/constants.dart';
import 'app_log_service.dart';
import 'device_info_service.dart';
import 'download_service.dart';
import 'eburonvoix_lite.dart';
import 'hive_service.dart';
import 'tts_background.dart';
import 'supertonic/flemish_text.dart';
import 'supertonic/supertonic_engine.dart';
import 'supertonic/supertonic_wav.dart';

/// Synthesizes one live chunk: returns PCM samples + sample rate.
typedef LiveSynth = Future<({List<double> samples, int sampleRate})> Function(
    String chunk);

/// Text-to-speech service: two on-device neural engines, nothing else.
///
/// - EburonVoix-3 (Supertonic 3, custom ORT pipeline): best quality,
///   31 languages, ~400 MB assets, needs a mid-range+ phone.
/// - EburonVoix-Lite (Piper nl_BE-nathalie via sherpa-onnx): tiny (~21 MB),
///   very fast, Flemish-only — the fallback for small phones.
///
/// No system TTS, no cloud. When auto-read is on (voice settings radio,
/// default on), new responses stream sentence-by-sentence to the selected
/// engine while the model is still generating; the speaker icon plays or
/// stops a single message manually without changing the setting.
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
  /// True when the voice bundle + espeak data are on disk in app-private
  /// storage, even if the engine isn't loaded yet. This is what was
  /// missing: downloads used to look absent after finishing.
  final liteDownloaded = false.obs;
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
        AppConstants.defaultTtsAutoRead;
    await refreshSupertonicStatus();
    await refreshLiteStatus();
    // Background audio: speaking state drives the Android media-playback
    // foreground service, so read-aloud keeps running when the app is
    // backgrounded. No-op on other platforms (facade stub).
    ever<bool>(isSpeaking, (speaking) {
      if (speaking) {
        unawaited(startTtsBackgroundAudio());
      } else {
        unawaited(stopTtsBackgroundAudio());
      }
    });
    _listenForNativeStop();
    // First-launch voice setup: the selected engine warms (auto-installing
    // its assets) while the tiny Lite bundle prefetches silently, so both
    // voices end up usable offline. Paths are app-private and re-resolved
    // every launch, so they survive updates without stored absolutes.
    if (engine.value == AppConstants.ttsEngineSupertonic3) {
      unawaited(_ensureNeuralEngine().catchError((_) {}));
    } else {
      unawaited(_ensureLiteEngine().catchError((_) {}));
    }
    unawaited(_prefetchLiteBundle().catchError((_) {}));
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
    // A stop always kills a live session too: the pump loop exits on the
    // bumped run id, so manual stops and manual speaks can never overlap
    // streamed auto-read playback.
    _liveRunId++;
    _liveQueue.clear();
    _liveActive = false;
    _liveFinal = false;
    _stopRequested = true;
    try {
      await _audioPlayer?.stop();
    } catch (_) {}
    isSpeaking.value = false;
  }

  // ── Live auto-read (streaming model responses) ──

  // A live session feeds the still-generating response sentence by sentence
  // to the selected engine: ChatController calls beginLiveRead() when
  // generation starts, feedLiveRead(accumulatedText) per token batch, and
  // endLiveRead() on completion. Playback starts with the first finished
  // sentence instead of waiting for the full answer.
  final _liveQueue = Queue<String>();
  var _liveRunId = 0;
  var _liveActive = false;
  var _liveFinal = false;
  var _livePumping = false;
  var _liveConsumed = '';
  var _liveLatestRaw = '';
  var _liveLastFeedMs = 0;
  LiveSynth? _liveSynth;

  /// Text of the in-flight prefetched chunk ([_pumpLive]): only reused when
  /// the queue head still matches, otherwise dropped — never repeat speech.
  String? _pendingText;

  static const _liveFeedMinIntervalMs = 350;

  /// Starts a live read-aloud session for a new model response. No-op
  /// unless auto-read is on and the selected engine is already usable —
  /// warming/loading stays on the manual speaker path, so auto-read never
  /// triggers silent downloads or load spinners mid-chat. Stops anything
  /// currently playing.
  Future<void> beginLiveRead() async {
    await stop(); // also invalidates any previous live session
    if (!autoRead.value) return;
    try {
      if (engine.value == AppConstants.ttsEngineLite) {
        final lite = _lite;
        if (!isLiteUsable || lite == null) {
          _log.info('[TTS] live read skipped: Lite engine not ready.');
          return;
        }
        _startLiveSession((c) async {
          final u = await Future(() => lite.synthesize(c, speed: rate.value));
          return (samples: u.samples, sampleRate: u.sampleRate);
        });
      } else {
        final neural = _neural;
        if (!isSupertonicUsable || neural == null) {
          _log.info('[TTS] live read skipped: EburonVoix-3 not ready.');
          return;
        }
        final style = await _loadNeuralStyle();
        final lang = _neuralLang();
        final speed = rate.value;
        final sr = neural.sampleRate;
        _startLiveSession((c) async {
          final wav = await neural.synthesize(
            c,
            style: style,
            lang: lang,
            speed: speed,
          );
          return (samples: wav, sampleRate: sr);
        });
      }
    } catch (e) {
      _log.error('[TTS] live read failed to start', details: e);
    }
  }

  void _startLiveSession(LiveSynth synth) {
    _liveRunId++;
    _liveQueue.clear();
    _liveActive = true;
    _liveFinal = false;
    _livePumping = false;
    _liveConsumed = '';
    _liveLatestRaw = '';
    _liveLastFeedMs = 0;
    _liveSynth = synth;
    _pendingText = null;
    _stopRequested = false;
    isSpeaking.value = true;
    _kickLivePump();
  }

  /// Feeds the latest accumulated response text. Cleaning/slicing runs at
  /// most every [_liveFeedMinIntervalMs]; [endLiveRead] always flushes the
  /// tail, so throttled frames are never lost.
  void feedLiveRead(String rawText) {
    if (!_liveActive) return;
    _liveLatestRaw = rawText;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _liveLastFeedMs < _liveFeedMinIntervalMs) return;
    _liveLastFeedMs = now;
    _ingestLive(_liveLatestRaw, false);
  }

  /// Flushes the remaining (possibly partial) tail and lets the queue
  /// drain. Safe to call when no session is active.
  void endLiveRead() {
    if (!_liveActive && _liveQueue.isEmpty) return;
    _liveLastFeedMs = 0;
    _ingestLive(_liveLatestRaw, true);
    _liveFinal = true;
    _kickLivePump();
  }

  /// Aborts a live session and stops playback. Safe to call anytime.
  void cancelLiveRead() {
    _liveQueue.clear();
    _liveActive = false;
    _liveFinal = false;
    _liveConsumed = '';
    _liveRunId++;
    unawaited(stop());
  }

  void _ingestLive(String raw, bool finalFlush) {
    final cleaned = FlemishText.normalize(speakableText(streamCleanText(raw)));
    if (cleaned.isEmpty) return;
    if (finalFlush) {
      for (final c in finalLiveChunks(cleaned, _liveConsumed)) {
        _liveQueue.add(c);
      }
      _liveConsumed = cleaned;
    } else {
      final slice = takeLiveSlice(cleaned, _liveConsumed);
      for (final seg in slice.ready) {
        for (final c in splitIntoChunks(seg)) {
          _liveQueue.add(c);
        }
      }
      _liveConsumed = slice.consumed;
    }
    _kickLivePump();
  }

  void _kickLivePump() {
    if (_livePumping || !_liveActive) return;
    final synth = _liveSynth;
    if (synth == null) return;
    _livePumping = true;
    unawaited(_pumpLive(_liveRunId, synth));
  }

  /// Sequential pump: synthesize each queued chunk and play it through the
  /// shared WAV pipeline. Stale runs (superseded by stop/speak/begin) exit
  /// without touching the newer session's flags.
  /// Sequential pump with next-chunk prefetch: while chunk N plays,
  /// chunk N+1 already synthesizes, so inference latency hides behind audio
  /// instead of surfacing as a pause between sentences. Stale runs
  /// (superseded by stop/speak/begin) exit without touching the newer
  /// session's flags; an in-flight prefetch is always dropped silently.
  Future<void> _pumpLive(int run, LiveSynth synth) async {
    Future<({List<double> samples, int sampleRate})>? pending;
    try {
      final player = await _player();
      final chunkFile = await _chunkFile();
      while (run == _liveRunId) {
        if (_liveQueue.isEmpty) {
          if (_liveFinal) break;
          await Future.delayed(const Duration(milliseconds: 120));
          continue;
        }
        final chunk = _liveQueue.removeFirst();
        if (chunk.trim().isEmpty) continue;
        Future<({List<double> samples, int sampleRate})> current;
        if (pending != null && _pendingText == chunk) {
          current = pending;
        } else {
          pending?.ignore();
          current = synth(chunk);
        }
        pending = null;
        _pendingText = null;
        // Prefetch the follower while the current synthesizes/plays.
        if (_liveQueue.isNotEmpty &&
            run == _liveRunId &&
            !_stopRequested) {
          _pendingText = _liveQueue.first;
          pending = synth(_pendingText!);
        }
        List<double> wav;
        int sr;
        try {
          final r = await current;
          wav = r.samples;
          sr = r.sampleRate;
        } catch (e) {
          _log.error('[TTS] live synthesis failed', details: e);
          break;
        }
        if (run != _liveRunId || _stopRequested) break;
        _log.info('[TTS] live chunk: ${wav.length} samples @ $sr Hz');
        if (!await _playChunk(wav, sr, player, chunkFile)) break;
      }
    } finally {
      pending?.ignore();
      // [pending] is pump-local; only the current run may clear the shared
      // prefetch tag, otherwise a stale pump would drop the new session's
      // in-flight synthesis.
      if (run == _liveRunId) _pendingText = null;
      if (run == _liveRunId) {
        _livePumping = false;
        _liveActive = false;
        isSpeaking.value = false;
      }
    }
  }

  /// Drops streaming-only noise before cleaning: an unclosed trailing code
  /// fence and any unclosed think/thought block (reasoning is never
  /// spoken). Pure (unit-tested).
  static String streamCleanText(String raw) {
    var out = raw;
    final fences = RegExp('```').allMatches(out).toList();
    if (fences.length.isOdd) out = out.substring(0, fences.last.start);
    for (final tag in ['<think>', '<thought>']) {
      final open = out.lastIndexOf(tag);
      if (open >= 0) {
        final close = out.indexOf('</${tag.substring(1)}', open);
        if (close < 0) out = out.substring(0, open);
      }
    }
    return out;
  }

  /// Slices newly completed sentences off streaming text. [cleaned] is the
  /// full cleaned response so far, [consumed] the prefix already queued.
  /// Only text ending in a sentence boundary is returned; the trailing
  /// partial sentence waits for more tokens. Boundary-less tails longer
  /// than 2×[maxLen] are force-flushed so speech never stalls. Pure
  /// (unit-tested).
  static ({List<String> ready, String consumed}) takeLiveSlice(
    String cleaned,
    String consumed, [
    int maxLen = 180,
  ]) {
    var start = 0;
    if (consumed.isNotEmpty) {
      // Never repeat speech: on non-monotonic input, hold and retry on the
      // next feed instead of guessing.
      if (!cleaned.startsWith(consumed)) {
        return (ready: const [], consumed: consumed);
      }
      start = consumed.length;
    }
    final rest = cleaned.substring(start);
    var cut = -1;
    for (final m in RegExp(r'[.!?…\n]\s+').allMatches(rest)) {
      cut = m.end;
    }
    if (cut < 0) {
      if (rest.length > maxLen * 2) {
        var cutAt = rest.lastIndexOf(RegExp(r'[ ,;:]\s'), maxLen);
        if (cutAt < maxLen ~/ 3) cutAt = maxLen;
        final piece = rest.substring(0, cutAt).trim();
        return (
          ready: piece.isEmpty ? const [] : [piece],
          consumed: consumed + rest.substring(0, cutAt),
        );
      }
      return (ready: const [], consumed: consumed);
    }
    final readyText = rest.substring(0, cut).trim();
    return (
      ready: readyText.isEmpty ? const [] : [readyText],
      consumed: consumed + rest.substring(0, cut),
    );
  }

  /// Remaining tail for [endLiveRead]: everything past [consumed],
  /// chunked normally (partial final sentence included). Pure
  /// (unit-tested).
  static List<String> finalLiveChunks(String cleaned, String consumed) {
    var tail = cleaned;
    if (consumed.isNotEmpty) {
      if (!cleaned.startsWith(consumed)) return [];
      tail = cleaned.substring(consumed.length);
    }
    return splitIntoChunks(tail);
  }

  Future<AudioPlayer> _player() async {
    final player = _audioPlayer ??= AudioPlayer();
    await player.setVolume(1.0);
    // Media usage + wake lock so chunks keep flowing in the background
    // under the foreground service.
    try {
      await player.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
        ),
      ));
    } catch (_) {}
    return player;
  }

  /// Notification Stop action (native shell) asks Dart to stop speech via
  /// the shared model-import channel. No-op anywhere it cannot work.
  void _listenForNativeStop() {
    try {
      const MethodChannel('com.aichat.ai_chat/model_import')
          .setMethodCallHandler((call) async {
        if (call.method == 'stopTts') await stop();
      });
    } catch (_) {}
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

  /// Plays [chunks] back-to-back with next-chunk prefetch: chunk N+1
  /// synthesizes while chunk N plays, hiding inference latency between
  /// sentences instead of pausing. A failed chunk aborts the rest; an
  /// in-flight prefetch is always dropped silently on stop/error.
  Future<void> _playChunksPipelined({
    required List<String> chunks,
    required String logLabel,
    required Future<({List<double> samples, int sampleRate})> Function(
            String chunk)
        synth,
  }) async {
    final player = await _player();
    final chunkFile = await _chunkFile();
    Future<({List<double> samples, int sampleRate})>? pending;
    try {
      for (var ci = 0; ci < chunks.length; ci++) {
        if (_stopRequested) {
          pending?.ignore();
          pending = null;
          break;
        }
        final current = pending ?? synth(chunks[ci]);
        pending = null;
        if (ci + 1 < chunks.length && !_stopRequested) {
          pending = synth(chunks[ci + 1]);
        }
        List<double> wav;
        int sr;
        try {
          final r = await current;
          wav = r.samples;
          sr = r.sampleRate;
        } catch (e) {
          _log.error('[TTS] $logLabel synthesis failed', details: e);
          pending?.ignore();
          pending = null;
          break;
        }
        if (_stopRequested) {
          pending?.ignore();
          pending = null;
          break;
        }
        _log.info('[TTS] $logLabel chunk ${ci + 1}/${chunks.length}: '
            '${wav.length} samples');
        if (!await _playChunk(wav, sr, player, chunkFile)) {
          pending?.ignore();
          pending = null;
          break;
        }
      }
    } finally {
      pending?.ignore();
    }
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
      final lang = _neuralLang();
      final speed = rate.value;
      final neural = _neural!;
      final sr = neural.sampleRate;
      await _playChunksPipelined(
        chunks: chunks,
        logLabel: 'neural',
        synth: (c) async {
          final wav = await neural.synthesize(
            c,
            style: style,
            lang: lang,
            speed: speed,
          );
          return (samples: wav, sampleRate: sr);
        },
      );
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
      liteDownloaded.value = files != null && _hasEspeak(files);
      if (files == null && liteState.value == 'ready') {
        liteState.value = 'idle';
        _lite?.dispose();
        _lite = null;
      }
    } catch (_) {}
  }

  /// Silently prefetches the Lite bundle on first launch (files only, no
  /// engine load — that happens on first Lite use). Never re-downloads a
  /// complete bundle; failures stay silent, the tile retries.
  Future<void> _prefetchLiteBundle() async {
    final files = await EburonVoixLiteFiles.locate(await _liteDir);
    if (files != null && _hasEspeak(files)) {
      liteDownloaded.value = true;
      return;
    }
    _log.info('[TTS] prefetching EburonVoix-Lite bundle…');
    await downloadLiteVoice(loadEngine: false);
  }

  /// Ensures the Lite voice is downloaded AND loaded. Reuses on-disk files
  /// (never re-downloads a complete bundle) — this is the single entry
  /// point the settings tile uses.
  Future<void> ensureLiteReady() async {
    final files = await EburonVoixLiteFiles.locate(await _liteDir);
    if (files != null && _hasEspeak(files)) {
      liteDownloaded.value = true;
      await _ensureLiteEngine();
      return;
    }
    await downloadLiteVoice();
  }

  String get liteStatusText {
    if (liteDownloaded.value &&
        liteState.value != 'ready' &&
        liteState.value != 'downloading' &&
        liteState.value != 'loading' &&
        liteState.value != 'error') {
      return 'Downloaded in app storage · tap to load';
    }
    return switch (liteState.value) {
      'downloading' =>
        'Downloading… ${(liteProgress.value * 100).toStringAsFixed(0)}% (tap to cancel)',
      'loading' => 'Loading Flemish voice…',
      'ready' => 'Flemish voice ready · offline',
      'error' => liteError.value.isEmpty
          ? 'Voice error — tap to retry'
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

  CancelToken? _liteCancel;

  /// Cancels an in-progress Lite voice download.
  void cancelLiteDownload() {
    _liteCancel?.cancel('cancelled by user');
  }

  /// Downloads the Piper nl_BE bundle (+ espeak data if the bundle lacks
  /// it) into app-private on-device storage (`<models>/eburonvoix-lite/`,
  /// no permissions needed), extracts, validates, and — unless
  /// [loadEngine] is false (silent prefetch) — loads the engine so the
  /// voice is immediately usable. Skips the download when a complete
  /// bundle is already on disk.
  Future<EburonVoixLiteFiles> downloadLiteVoice({bool loadEngine = true}) async {
    if (liteState.value == 'downloading') {
      throw 'Download already in progress.';
    }
    liteState.value = 'downloading';
    liteError.value = '';
    liteProgress.value = 0.0;
    final cancel = _liteCancel = CancelToken();
    try {
      final dir = await _liteDir;
      var files = await EburonVoixLiteFiles.locate(dir);
      if (files == null || !_hasEspeak(files)) {
        await _downloadAndExtract(
          AppConstants.liteBundleUrl,
          dir,
          0.0,
          0.85,
          cancel,
        );
        files = await EburonVoixLiteFiles.locate(dir);
        if (files == null || !_hasEspeak(files)) {
          await _downloadAndExtract(
            AppConstants.liteEspeakUrl,
            '$dir/espeak-ng-data',
            0.85,
            1.0,
            cancel,
          );
          files = await EburonVoixLiteFiles.locate(dir);
        }
      }
      final located = files;
      if (located == null || !_hasEspeak(located)) {
        throw 'Voice files incomplete after download. Delete and retry.';
      }
      liteDownloaded.value = true;
      await refreshLiteStatus();
      _log.info('[TTS] EburonVoix-Lite bundle on disk, loading engine…');
    } catch (e) {
      // User-cancelled downloads go quietly back to idle; real failures
      // surface as errors with a retry path.
      if ('$e'.contains('cancelled')) {
        liteState.value = 'idle';
        liteError.value = '';
      } else {
        liteState.value = 'error';
        liteError.value = '$e';
      }
      _log.error('[TTS] Lite voice download failed', details: e);
      rethrow;
    } finally {
      _liteCancel = null;
      if (liteState.value == 'downloading') liteState.value = 'idle';
    }
    // Load immediately so a finished download is usable, not stranded
    // (skipped for silent prefetches — first Lite use loads then).
    if (loadEngine) await _ensureLiteEngine();
    final ready = await EburonVoixLiteFiles.locate(await _liteDir);
    if (ready == null) throw 'Voice files vanished after download.';
    return ready;
  }

  bool _hasEspeak(EburonVoixLiteFiles files) =>
      Directory(files.espeakDir).existsSync();

  Future<void> _downloadAndExtract(
    String url,
    String destDir,
    double from,
    double to,
    CancelToken cancel,
  ) async {
    final tmpFile =
        File('$destDir/.download-${DateTime.now().millisecondsSinceEpoch}');
    try {
      await Dio().download(
        url,
        tmpFile.path,
        cancelToken: cancel,
        deleteOnError: true,
        options: Options(
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 15),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            liteProgress.value = from + (to - from) * received / total;
          }
        },
      );
      if (cancel.isCancelled) throw 'Download cancelled.';
      final bytes = await tmpFile.readAsBytes();
      // Reject server error pages before touching the extractor: bzip2
      // streams always start with the 'BZh' magic.
      if (bytes.length < 10 ||
          bytes[0] != 0x42 || // B
          bytes[1] != 0x5A || // Z
          bytes[2] != 0x68) {
        // h
        throw 'Voice server returned an error page — check connection and retry.';
      }
      final tarBytes = BZip2Decoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(tarBytes);
      for (final file in archive.files) {
        if (cancel.isCancelled) throw 'Download cancelled.';
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
      final speed = rate.value;
      await _playChunksPipelined(
        chunks: chunks,
        logLabel: 'lite',
        synth: (c) async {
          final utterance =
              await Future(() => lite.synthesize(c, speed: speed));
          return (
            samples: utterance.samples,
            sampleRate: utterance.sampleRate
          );
        },
      );
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
  /// utterance. 180 chars (~12 s audio) keeps per-chunk inference latency
  /// low so pipelined playback never starves. Pure (unit-tested).
  static List<String> splitIntoChunks(String text, [int maxLen = 180]) {
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

  /// Roleplay markers (`*sigh*`, `*lacht*`, …) mapped to the engine's
  /// expression tags. Anything else in asterisks keeps the old behavior
  /// (markers stripped, word spoken). Pure (unit-tested).
  static const _expressionMarkers = <String, String>{
    'sigh': 'sigh',
    'sighs': 'sigh',
    'sighed': 'sigh',
    'sighing': 'sigh',
    'zucht': 'sigh',
    'zuchtte': 'sigh',
    'zuchtend': 'sigh',
    'laugh': 'laugh',
    'laughs': 'laugh',
    'laughed': 'laugh',
    'laughing': 'laugh',
    'lacht': 'laugh',
    'lachte': 'laugh',
    'lachend': 'laugh',
    'giggle': 'laugh',
    'giggles': 'laugh',
    'giggled': 'laugh',
    'grinnikt': 'laugh',
    'grinnikte': 'laugh',
    'breath': 'breath',
    'breathed': 'breath',
    'breathing': 'breath',
    'adem': 'breath',
    'ademt': 'breath',
    'ademend': 'breath',
    'gasp': 'breath',
    'gasps': 'breath',
    'hijgt': 'breath',
  };

  /// Strips reasoning traces and markdown so TTS reads words, not syntax.
  /// Humanizing: `...`/`…` becomes an audible `<breath>`, and `*sigh*`-style
  /// roleplay markers become the matching expression tag (EburonVoix-3
  /// renders them; Lite strips them silently instead of reading them aloud).
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
    out = out.replaceAll(RegExp(r'\.{2,}|…'), ' <breath> ');
    out = out.replaceAllMapped(RegExp(r'\*([A-Za-z]+)\*'), (m) {
      final tag = _expressionMarkers[(m.group(1) ?? '').toLowerCase()];
      return tag == null ? ' ${m.group(1)} ' : ' <$tag> ';
    });
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
