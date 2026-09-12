import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../core/constants.dart';
import '../services/app_log_service.dart';
import '../services/hive_service.dart';
import '../services/image_generation_notification_service.dart';
import '../services/inference_service.dart';
import '../services/openai_server_service.dart';

class ServerController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final InferenceService inference = Get.find<InferenceService>();
  final OpenAiServerService _server = OpenAiServerService();

  final isRunning = false.obs;
  final isStarting = false.obs;
  final localUrl = RxnString();
  final serverStatus = 'Server stopped'.obs;
  final lastError = RxnString();

  final useApiKey = false.obs;
  final apiKey = ''.obs;

  late final TextEditingController apiKeyCtrl;

  static const int port = 8080;
  static const int _portScanCount = 20;

  @override
  void onInit() {
    super.onInit();
    useApiKey.value =
        _hive.getSetting<bool>(AppConstants.keyServerUseApiKey) ?? false;
    apiKey.value = _hive.getSetting<String>(AppConstants.keyServerApiKey) ?? '';

    apiKeyCtrl = TextEditingController(text: apiKey.value);
  }

  bool get hasLocalModel => inference.isModelLoaded.value;

  String get modelName => inference.loadedModelName.value.isEmpty
      ? 'No model loaded'
      : inference.loadedModelName.value;

  Future<void> toggleServer(bool enabled) async {
    if (enabled) {
      await startServer();
    } else {
      await stopServer();
    }
  }

  Future<void> startServer() async {
    if (isRunning.value || isStarting.value) return;
    lastError.value = null;
    if (!hasLocalModel) {
      lastError.value = 'Load a local GGUF or LiteRT-LM model first.';
      Get.snackbar('Server not started', lastError.value!);
      return;
    }

    isStarting.value = true;
    serverStatus.value = 'Starting server...';
    await saveSettings();

    try {
      final boundPort = await _bindFirstAvailablePort();
      final url = _server.localUrl;
      localUrl.value = url;
      isRunning.value = true;

      var backgroundReady = false;
      if (url != null &&
          Get.isRegistered<ImageGenerationNotificationService>()) {
        try {
          await Get.find<ImageGenerationNotificationService>()
              .startApiServer(url: url);
          backgroundReady = true;
        } catch (e) {
          Get.find<AppLogService>().warning(
            'API server foreground keep-alive failed',
            details: e,
          );
        }
      }

      final portMessage = boundPort == port
          ? 'Port $boundPort'
          : 'Port $port busy · using $boundPort';
      serverStatus.value = backgroundReady
          ? '$portMessage · background enabled'
          : '$portMessage · server running';
    } catch (e) {
      lastError.value = '$e';
      serverStatus.value = 'Server failed';
      Get.find<AppLogService>().error('API server failed', details: e);
      Get.snackbar('Server failed', '$e');
      if (_server.isRunning) {
        await _server.stop();
      }
      isRunning.value = false;
      localUrl.value = null;
    } finally {
      isStarting.value = false;
    }
  }

  /// Binds the preferred API port first, then falls forward when another app
  /// (for example Termux or a stale dev server) already owns it. Android reports
  /// this as errno=98. The selected port is reflected by [_server.localUrl], so
  /// clients always receive the real endpoint rather than a hard-coded 8080.
  Future<int> _bindFirstAvailablePort() async {
    Object? lastAddressInUseError;

    for (var offset = 0; offset < _portScanCount; offset++) {
      final candidatePort = port + offset;
      try {
        await _server.start(
          port: candidatePort,
          apiKey: useApiKey.value ? apiKey.value : null,
          onLog: (message) => serverStatus.value = message,
        );
        return candidatePort;
      } catch (e) {
        if (!_isAddressAlreadyInUse(e)) rethrow;
        lastAddressInUseError = e;
        Get.find<AppLogService>().warning(
          'API port $candidatePort is already in use; trying next port',
          details: e,
        );
      }
    }

    throw StateError(
      'No free API port found in $port-${port + _portScanCount - 1}. '
      'Last bind error: ${lastAddressInUseError ?? 'unknown'}',
    );
  }

  bool _isAddressAlreadyInUse(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('address already in use') ||
        text.contains('errno = 98') ||
        text.contains('errno = 48') ||
        text.contains('10048');
  }

  Future<void> stopServer() async {
    isStarting.value = false;
    await _server.stop();

    if (Get.isRegistered<ImageGenerationNotificationService>()) {
      try {
        await Get.find<ImageGenerationNotificationService>().stopApiServer();
      } catch (e) {
        Get.find<AppLogService>().warning(
          'API server foreground keep-alive cleanup failed',
          details: e,
        );
      }
    }

    isRunning.value = false;
    localUrl.value = null;
    serverStatus.value = 'Server stopped';
    lastError.value = null;
  }

  Future<void> saveSettings() async {
    await _hive.setSetting(AppConstants.keyServerUseApiKey, useApiKey.value);
    await _hive.setSetting(AppConstants.keyServerApiKey, apiKey.value.trim());
  }

  Future<void> generateApiKey() async {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    apiKey.value =
        'aichat_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    apiKeyCtrl.text = apiKey.value;
    useApiKey.value = true;
    await saveSettings();
  }

  Future<void> copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    Get.snackbar('Copied', '$label copied.');
  }

  String get baseUrl => localUrl.value ?? 'http://localhost:$port';

  String get openAiBaseUrl => '$baseUrl/v1';

  @override
  void onClose() {
    apiKeyCtrl.dispose();
    unawaited(stopServer());
    super.onClose();
  }
}
