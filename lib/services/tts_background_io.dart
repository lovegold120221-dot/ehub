import 'dart:io';

import 'package:flutter/services.dart';

/// Native bridge to the Android media-playback foreground service
/// ([TtsPlaybackService]). Started while the app is in the foreground the
/// moment speech begins, it keeps the process (synthesis + playback) alive
/// when the user backgrounds the app. Stopping is always safe.
const _channel = MethodChannel('com.orailnoor.privatelm/tts_playback');

Future<void> startTtsBackgroundAudio() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod('startPlayback');
  } catch (_) {}
}

Future<void> stopTtsBackgroundAudio() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod('stopPlayback');
  } catch (_) {}
}
