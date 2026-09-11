package com.orailnoor.privatelm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/// Foreground service that keeps TTS read-aloud (synthesis + playback)
/// running while the app is backgrounded.
///
/// Started from the foreground the moment speech begins (Dart calls
/// `startPlayback` on the tts_playback channel when `isSpeaking` turns
/// true) and stopped when speech ends. Starting from the foreground keeps
/// this legal on Android 12+ background-start rules; stopping is always
/// allowed. Never started from the background.
class TtsPlaybackService : Service() {
    companion object {
        const val ACTION_START = "com.orailnoor.privatelm.tts.START"
        const val ACTION_STOP = "com.orailnoor.privatelm.tts.STOP"
        const val EXTRA_STOP_TTS = "com.orailnoor.privatelm.tts.STOP_TTS"
        private const val CHANNEL_ID = "tts_playback"
        private const val NOTIF_ID = 4407
        private const val TAG = "TtsPlayback"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Log.i(TAG, "Stopping read-aloud service")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        runAsForeground()
        return START_NOT_STICKY
    }

    private fun runAsForeground() {
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            44071,
            packageManager.getLaunchIntentForPackage(packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        // Notification actions may start activities (BAL-exempt), so Stop
        // routes through MainActivity: it forwards `stopTts` to Dart and
        // stops this service. Tapping Stop never strands audio playing.
        val stopIntent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_STOP
            putExtra(EXTRA_STOP_TTS, true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val stop = PendingIntent.getActivity(
            this,
            44072,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("EburonHub is reading aloud")
            .setContentText("Tap to open · Stop ends read-aloud")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop",
                stop
            )
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Read aloud",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows while EburonHub reads answers aloud"
                setShowBadge(false)
            }
        )
    }
}
