import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Owns the Android foreground-service keep-alive used by long-running local
/// work. Image generation and the local OpenAI API can run at the same time;
/// each feature acquires its own lease so one feature cannot accidentally stop
/// the foreground service while the other still needs it.
class ImageGenerationNotificationService {
  static const int _progressNotificationId = 4201;
  static const int _foregroundNotificationId = 4202;
  static const String _channelId = 'image_generation_progress';
  static const String _channelName = 'EburonHub background activity';

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _notifications.initialize(settings);
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description:
                'Keeps the local API server and long-running local AI tasks active',
            importance: Importance.low,
          ),
        );
    _initialized = true;
  }

  Future<void> configureBackgroundService() async {
    if (!Platform.isAndroid) return;
    await FlutterBackgroundService().configure(
      androidConfiguration: AndroidConfiguration(
        onStart: eburonBackgroundStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'EburonHub running in background',
        initialNotificationContent: 'Keeping local AI services available.',
        foregroundServiceNotificationId: _foregroundNotificationId,
        foregroundServiceTypes: const [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
  }

  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await Permission.notification.request();
  }

  Future<void> ensurePermission() async {
    if (!Platform.isAndroid) return;
    await _requestNotificationPermission();
    await Permission.ignoreBatteryOptimizations.request();
  }

  /// Acquires the foreground-service lease for the local OpenAI-compatible API.
  /// The actual HttpServer remains owned by the app isolate; this service keeps
  /// the Android process alive when the UI moves to the background.
  Future<void> startApiServer({required String url}) async {
    if (!Platform.isAndroid) return;
    await init();
    await _requestNotificationPermission();
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    service.invoke('apiServerActive', {'content': 'Listening on $url'});
  }

  /// Releases only the API-server lease. Image generation, when active, keeps
  /// the foreground service alive.
  Future<void> stopApiServer() async {
    if (!Platform.isAndroid) return;
    FlutterBackgroundService().invoke('apiServerInactive');
  }

  Future<void> start({
    required String modelName,
    required String backend,
    required int steps,
    required String sizeLabel,
  }) async {
    if (!Platform.isAndroid) return;
    await init();
    await ensurePermission();
    final details =
        '$backend · $sizeLabel · $steps ${steps == 1 ? "step" : "steps"}';
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    service.invoke('imageActive', {'content': details});
    service.invoke('progress', {'content': details});
    await _showProgress(
      title: 'Image generation running',
      body: '0% · Step 0 of $steps',
      progress: 0,
      maxProgress: steps <= 0 ? 100 : steps,
      indeterminate: steps <= 0,
    );
  }

  Future<void> update({
    required int step,
    required int total,
    required int etaSeconds,
    required int elapsedSeconds,
  }) async {
    if (!Platform.isAndroid) return;
    final percent = total > 0 ? ((step / total) * 100).clamp(0, 100).round() : 0;
    final eta = etaSeconds > 0 ? ' · ~${_formatEta(etaSeconds)} left' : '';
    final elapsed = ' · ${_formatEta(elapsedSeconds)} elapsed';
    final body = total > 0
        ? '$percent% · Step $step of $total$elapsed$eta'
        : 'Working$elapsed';
    FlutterBackgroundService().invoke('progress', {'content': body});
    await _showProgress(
      title: 'Image generation running',
      body: body,
      progress: total > 0 ? step.clamp(0, total).toInt() : 0,
      maxProgress: total <= 0 ? 100 : total,
      indeterminate: total <= 0,
    );
  }

  Future<void> decoding() async {
    if (!Platform.isAndroid) return;
    FlutterBackgroundService().invoke('progress', {'content': 'Decoding image...'});
    await _showProgress(
      title: 'Finishing image',
      body: 'Decoding image...',
      progress: 100,
      maxProgress: 100,
      indeterminate: true,
    );
  }

  Future<void> complete({required int durationMs}) async {
    if (!Platform.isAndroid) return;
    await _notifications.show(
      _progressNotificationId,
      'Image ready',
      'Generation finished in ${_formatDuration(durationMs)}.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription:
              'Keeps the local API server and long-running local AI tasks active',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
        ),
      ),
    );
    FlutterBackgroundService().invoke('imageInactive');
  }

  Future<void> failed() async {
    if (!Platform.isAndroid) return;
    await _notifications.show(
      _progressNotificationId,
      'Image generation failed',
      'Open EburonHub to check the error and try again.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription:
              'Keeps the local API server and long-running local AI tasks active',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
        ),
      ),
    );
    FlutterBackgroundService().invoke('imageInactive');
  }

  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    await _notifications.cancel(_progressNotificationId);
    FlutterBackgroundService().invoke('imageInactive');
  }

  Future<void> _showProgress({
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
    required bool indeterminate,
  }) async {
    await _notifications.show(
      _foregroundNotificationId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription:
              'Keeps the local API server and long-running local AI tasks active',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: maxProgress,
          progress: progress,
          indeterminate: indeterminate,
        ),
      ),
    );
  }

  String _formatEta(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
  }

  String _formatDuration(int ms) {
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
  }
}

@pragma('vm:entry-point')
void eburonBackgroundStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  var imageActive = false;
  var apiServerActive = false;
  var imageContent = 'Local image generation is running.';
  var apiContent = 'Local OpenAI API server is running.';

  void refreshForegroundState() {
    if (service is AndroidServiceInstance) {
      if (imageActive) {
        service.setForegroundNotificationInfo(
          title: 'Image generation running',
          content: imageContent,
        );
      } else if (apiServerActive) {
        service.setForegroundNotificationInfo(
          title: 'EburonHub API server running',
          content: apiContent,
        );
      }
    }

    if (!imageActive && !apiServerActive) {
      service.stopSelf();
    }
  }

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
  }

  service.on('imageActive').listen((event) {
    imageActive = true;
    imageContent = event?['content'] as String? ?? imageContent;
    refreshForegroundState();
  });

  service.on('progress').listen((event) {
    imageActive = true;
    imageContent = event?['content'] as String? ?? imageContent;
    refreshForegroundState();
  });

  service.on('imageInactive').listen((event) {
    imageActive = false;
    refreshForegroundState();
  });

  service.on('apiServerActive').listen((event) {
    apiServerActive = true;
    apiContent = event?['content'] as String? ?? apiContent;
    refreshForegroundState();
  });

  service.on('apiServerInactive').listen((event) {
    apiServerActive = false;
    refreshForegroundState();
  });

  // Backwards-compatible force-stop hook for any older callers.
  service.on('stopService').listen((event) {
    imageActive = false;
    apiServerActive = false;
    service.stopSelf();
  });
}
