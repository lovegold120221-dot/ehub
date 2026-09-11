#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
tts_path = ROOT / "lib/services/tts_service.dart"
test_path = ROOT / "test/tts_service_test.dart"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


tts = tts_path.read_text()

# Stop must invalidate any queued/prefetched synthesis from the old live run.
tts = replace_once(
    tts,
    """    _liveQueue.clear();
    _liveActive = false;
    _liveFinal = false;
    _stopRequested = true;
""",
    """    _liveQueue.clear();
    _liveActive = false;
    _liveFinal = false;
    _pendingLiveSynth?.ignore();
    _pendingLiveSynth = null;
    _pendingText = null;
    _livePlaybackActive = false;
    _stopRequested = true;
""",
    "stop live prefetch reset",
)

# Make the next synthesis a session-level future so text arriving DURING
# playback can immediately become the prefetch instead of waiting for the
# current chunk to finish.
tts = replace_once(
    tts,
    """  /// Text of the in-flight prefetched chunk ([_pumpLive]): only reused when
  /// the queue head still matches, otherwise dropped — never repeat speech.
  String? _pendingText;

  static const _liveFeedMinIntervalMs = 350;
""",
    """  /// Text/future for the one-chunk-ahead live prefetch. These are shared
  /// with [feedLiveRead], so a sentence that becomes ready while chunk N is
  /// already playing can start synthesizing immediately instead of waiting
  /// for playback to finish.
  String? _pendingText;
  Future<({List<double> samples, int sampleRate})>? _pendingLiveSynth;
  bool _livePlaybackActive = false;

  // Keep sentence-boundary detection responsive without doing the markdown /
  // normalization pass on every token callback.
  static const _liveFeedMinIntervalMs = 80;
""",
    "live prefetch state",
)

tts = replace_once(
    tts,
    """    _liveKeepTags = keepTags;
    _pendingText = null;
    _stopRequested = false;
""",
    """    _liveKeepTags = keepTags;
    _pendingLiveSynth?.ignore();
    _pendingLiveSynth = null;
    _pendingText = null;
    _livePlaybackActive = false;
    _stopRequested = false;
""",
    "start live reset",
)

# Prime immediately after newly completed text is queued. The helper is a
# no-op unless audio is currently playing, which avoids running two model
# inferences against the same TTS engine at the same time.
tts = replace_once(
    tts,
    """      _liveConsumed = slice.consumed;
    }
    _kickLivePump();
  }
""",
    """      _liveConsumed = slice.consumed;
    }
    _primeLivePrefetch(_liveRunId);
    _kickLivePump();
  }
""",
    "prime on ingest",
)

kick_marker = """  void _kickLivePump() {
"""
if tts.count(kick_marker) != 1:
    raise SystemExit("kick marker: expected exactly one match")
prime_helper = """  void _primeLivePrefetch(int run) {
    final synth = _liveSynth;
    if (!_livePlaybackActive ||
        synth == null ||
        run != _liveRunId ||
        _stopRequested ||
        _pendingLiveSynth != null ||
        _liveQueue.isEmpty) {
      return;
    }
    _pendingText = _liveQueue.first;
    _pendingLiveSynth = synth(_pendingText!);
  }

"""
tts = tts.replace(kick_marker, prime_helper + kick_marker, 1)

# Replace the old pump. The old code only selected a follower before current
# synthesis/playback began. If the model completed the next sentence later,
# it could not prefetch and the user heard an inference-sized pause.
pump_pattern = re.compile(
    r"  Future<void> _pumpLive\(int run, LiveSynth synth\) async \{.*?\n  \}\n\n(?=  /// Drops streaming-only noise)",
    re.S,
)
new_pump = """  Future<void> _pumpLive(int run, LiveSynth synth) async {
    try {
      final player = await _player();
      final chunkFile = await _chunkFile();
      while (run == _liveRunId) {
        if (_liveQueue.isEmpty) {
          if (_liveFinal) break;
          // feedLiveRead can queue a completed sentence at any time. Polling
          // at 20 ms keeps first-audio latency low without a busy loop.
          await Future.delayed(const Duration(milliseconds: 20));
          continue;
        }

        final chunk = _liveQueue.removeFirst();
        if (chunk.trim().isEmpty) continue;

        Future<({List<double> samples, int sampleRate})> current;
        if (_pendingLiveSynth != null && _pendingText == chunk) {
          current = _pendingLiveSynth!;
        } else {
          // A stale prefetch can only happen after non-monotonic/aborted text;
          // never reuse it for a different queue head.
          _pendingLiveSynth?.ignore();
          current = synth(chunk);
        }
        _pendingLiveSynth = null;
        _pendingText = null;

        List<double> wav;
        int sr;
        try {
          final synthSw = Stopwatch()..start();
          final r = await current;
          synthSw.stop();
          wav = r.samples;
          sr = r.sampleRate;
          final audioMs = (wav.length / sr * 1000).round();
          _log.info('[TTS] live chunk: synth=${synthSw.elapsedMilliseconds}ms '
              'audio=${audioMs}ms');
        } catch (e) {
          _log.error('[TTS] live synthesis failed', details: e);
          break;
        }
        if (run != _liveRunId || _stopRequested) break;

        bool played = false;
        _livePlaybackActive = true;
        // If a follower is already queued, start it now. If it arrives later
        // while this audio is still playing, _ingestLive() calls the same
        // helper and starts it then. This is the key no-long-pause behavior.
        _primeLivePrefetch(run);
        try {
          played = await _playChunk(wav, sr, player, chunkFile);
        } catch (e) {
          _log.error('[TTS] chunk playback failed', details: e);
          break;
        } finally {
          if (run == _liveRunId) _livePlaybackActive = false;
        }
        if (!played) {
          _log.info('[TTS] live pump stopped after chunk');
          break;
        }
      }
    } finally {
      // Only the current run may touch shared live-prefetch state. A stale
      // pump can finish after beginLiveRead() has already created a new run.
      if (run == _liveRunId) {
        _pendingLiveSynth?.ignore();
        _pendingLiveSynth = null;
        _pendingText = null;
        _livePlaybackActive = false;
        _log.info('[TTS] live session ended '
            '(final=$_liveFinal, queued=${_liveQueue.length})');
        _livePumping = false;
        _liveActive = false;
        isSpeaking.value = false;
      }
    }
  }

"""
tts, pump_count = pump_pattern.subn(lambda _: new_pump, tts, count=1)
if pump_count != 1:
    raise SystemExit(f"pump replacement: expected one match, found {pump_count}")

# Detect a sentence as soon as punctuation reaches the end of the current
# stream chunk; do not require a later whitespace token. Also force a natural
# cut after ~96 chars for punctuation-free model output so speech starts early.
tts = replace_once(
    tts,
    """    int maxLen = 120,
""",
    """    int maxLen = 96,
""",
    "live slice max length",
)
tts = replace_once(
    tts,
    """    for (final m in RegExp(r'[.!?…\\n]\\s+').allMatches(rest)) {
""",
    """    for (final m in RegExp(r'[.!?…\\n](?:\\s+|$)').allMatches(rest)) {
""",
    "sentence boundary at stream end",
)
tts = replace_once(
    tts,
    """      if (rest.length > maxLen * 2) {
""",
    """      if (rest.length >= maxLen) {
""",
    "earlier boundary-less flush",
)

# A durable fsync for a disposable WAV on every sentence adds avoidable I/O
# latency between chunks. Closing the file is enough for immediate playback.
tts = replace_once(
    tts,
    """        flush: true);
""",
    """        flush: false);
""",
    "streaming wav write",
)

tts_path.write_text(tts)

# Regression test: punctuation at the current end-of-stream must be readable
# immediately, otherwise TTS waits for another token and creates a pause.
test = test_path.read_text()
needle = """    test('never repeats on non-monotonic input', () {
"""
if "emits a sentence when punctuation is at stream end" not in test:
    if test.count(needle) != 1:
        raise SystemExit("test insertion marker: expected exactly one match")
    addition = """    test('emits a sentence when punctuation is at stream end', () {
      final s = TtsService.takeLiveSlice('Hallo wereld.', '');
      expect(s.ready, ['Hallo wereld.']);
      expect(s.consumed, 'Hallo wereld.');
    });

"""
    test = test.replace(needle, addition + needle, 1)
    test_path.write_text(test)

print('Applied continuous streaming TTS patch.')
