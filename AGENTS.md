# AGENTS.md — EburonHub (cross-platform-llm-client)

Flutter + GetX + Hive AI chat client. Local GGUF/LiteRT inference on Android/iOS, cloud APIs everywhere.

## Branding

- Display name is **EburonHub** (Android label, iOS bundle name, web title/manifest, in-app strings). Launcher + in-app logo source: `assets/icons/app_logo.png` (its off-white background must be flooded to black when regenerating the PNG sets).
- Identity stays `privatelm`: Dart package (`package:privatelm/...`), Android `applicationId`/`namespace` `com.orailnoor.privatelm`, iOS bundle IDs, Firebase project IDs. Renaming any of these breaks upgrades, Firebase app IDs, and imports — don't.

## Commands

```bash
flutter pub get
flutter analyze
flutter test                        # one fast pure-Dart test: test/ai_model_test.dart
flutter test test/ai_model_test.dart # focused run
flutter build apk --debug
flutter build web --release
firebase deploy --only hosting      # serves build/web (see firebase.json)
```

- Release APK: `cp android/key.properties.example android/key.properties` (fill keystore), then `flutter build apk --release --split-per-abi`. Release builds **fail** without `android/key.properties` unless `PRIVATELM_ALLOW_DEBUG_RELEASE_SIGNING=true`. Bump `version: x.y.z+N` in `pubspec.yaml` for each release (Android rejects same-build-number upgrades).
- No CI, no lint-staged, no codegen. `flutter analyze` (flutter_lints) is the only static gate.

## Architecture

- Entry: `lib/main.dart` — Get service registration order matters: `AppLogService → HiveService → DeviceInfoService → Settings/CloudModel → Inference/Cloud/Download/LocalImage → CrashReporting → notifications → Server/ModelController`. Routes: `lib/core/routes.dart`, keys/defaults: `lib/core/constants.dart`. Chat recalls past conversations into the system prompt (`ChatController._memoryBlock`/`buildMemoryBlock`, unit-tested, toggle `memory_enabled` default-on, caps in `AppConstants.memory*`); current chat always dominates context.
- UI (`lib/views/`) → GetX controllers (`lib/controllers/`) → services (`lib/services/`). Persistence is 4 schemaless Hive boxes (sessions/messages/tasks/settings, plain Maps, no adapters) in `lib/services/hive_service.dart`.

## Platform splits — do not break these

- Never import `*_android.dart`, `download_native.dart`, `device_info_native.dart`, or `dart:io` `Platform` from shared code. Always go through the facade:
  - `inference_service.dart` → `inference_android.dart if (dart.library.html) inference_stub.dart`
  - Same pattern: `download_native/web.dart`, `openai_server_service_io/stub.dart`, `device_info_native/web.dart`.
- `supportsLocalInference` is true only on Android/iOS. Web is cloud-only; `DownloadService.supportsDownload` is false on web.

## Inference gotchas

- Runtime dispatch by extension: `.litertlm` → LiteRT engine, `.gguf` → llama; `.safetensors` is rejected by the text engine. Switching runtimes mid-session requires app restart (`requiresAppRestartForRuntime`).
- Known device bug: Gemma Q4_K_M produces empty output on Pixel Tensor SoCs — suggest Q4_0/Q5_K_M, another model family, or Cloud mode.
- `pubspec.yaml` uses **path overrides** for all native plugins in `local_plugins/` (`llama_flutter_android`, `sd_flutter_android`, `flutter_litert_lm`). Editing plugin code changes the app; `flutter pub get` resolves locally.
- `local_plugins/sd_flutter_android` embeds a **git submodule** (`android/src/main/cpp/stable-diffusion.cpp`). Fresh clones need `git submodule update --init` or the native build fails.

## Secrets / Firebase
- `lib/firebase_options.dart`, `google-services.json`, `GoogleService-Info.plist`, `android/key.properties`, `*.jks` are gitignored and absent. Firebase init in `main.dart` is intentionally commented out; the gradle google-services/crashlytics plugins apply only if `google-services.json` exists. Do not re-enable Firebase without generating `firebase_options.dart` via FlutterFire.
- API keys live in Hive settings, sent only to the chosen provider endpoint (`CloudService` normalizes OpenAI/Anthropic/Gemini/Kimi shapes).

## Voice / TTS

- `TtsService` owns voice state — two on-device neural engines, nothing else: **EburonVoix-3** (Supertonic 3 via custom ORT pipeline in `lib/services/supertonic/`) and **EburonVoix-Lite** (Piper `nl_BE-nathalie` int8 via `sherpa_onnx`, voice bundle + espeak data under `<models>/eburonvoix-lite/`). No system TTS, no cloud. `local_plugins/onnxruntime` is a fork with its `.so` files REMOVED — sherpa_onnx already ships ORT (dupes break the build); the Dart FFI bindings drive sherpa's lib. Shared sentence-chunked WAV playback (`tts_chunk.wav`), persisted auto-read radio (Auto default-on, Manual). Speaker icon in chat bubbles plays/stops one message; auto-read streams from `ChatController` via `begin/feed/endLiveRead` (pure slice helpers `streamCleanText`/`takeLiveSlice`/`finalLiveChunks` are unit-tested — never repeat speech on non-monotonic input). Chunks are ≤180 chars and synthesize pipelined (next while current plays) so there are no gaps; `...`→`<breath>` and `*sigh*`-style markers become Supertonic expression tags (Lite strips them). The Lite bundle lives in app-private `<models>/eburonvoix-lite/` (no storage permission needed); `downloadLiteVoice` is idempotent, validates downloads, supports cancel, and loads the engine at once — `ensureLiteReady` is the tile entry point, `liteDownloaded` tracks on-disk state. Speech survives backgrounding on Android via the `mediaPlayback` foreground service (`TtsPlaybackService`, driven by `isSpeaking` through the `tts_background.dart` facade; notification has tap-to-open + Stop, which forwards `stopTts` to Dart) — never import it or `dart:io` `Platform` from shared code, always go through the facade.
- Supertonic assets live under `<models>/supertonic-3/` (ignored by the model list); `unicode_indexer.json` is all-int, voice-style `data` is NESTED (flatten it — see `loadStyle`). Supertonic language table: `AppConstants.supertonicLanguages` (31). Assets auto-install on first neural use with `.part` files + retry + size/JSON validation (`supertonicAssetProblems`) — never trust bare file existence.
- Flemish adaptation is TEXT, not files: sherpa's Piper path phonemizes purely via espeak and ignores custom lexicon files (verified in `piper-phonemize-lexicon.cc`), and Supertonic has no lexicon concept — so all nl-BE fixes live in `lib/services/supertonic/flemish_text.dart` (homophone respellings verified with `espeak-ng -v nl --ipa` against the voice's `tokens.txt`, acronym/abbrev/unit expansions, prosody shaping, expression-tag filtering). It runs before both engines. Only `<laugh>/<breath>/<sigh>` pass through to Supertonic (verified in its indexer); Lite strips all tags.
