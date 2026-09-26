package cn.wenxiang.wenxiang

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/// Keeps the Wenxiang process alive so the in-app WebSocket listener can
/// receive inbox pushes (answer-completion, build, Claude Code task events)
/// while the app is in the background.
///
/// Uses Android 14+ `dataSync` foreground service type. Android imposes a
/// ~6 hour cap on a single `startForeground` call for `dataSync`, so the
/// service self-restarts at 5 h to stay under the limit.
class SyncService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val watchdog = Runnable {
        try {
            stopForegroundCompat()
        } catch (_: Exception) {
        }
        val restart = Intent(this, SyncService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(restart)
            } else {
                startService(restart)
            }
        } catch (_: Exception) {
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        handler.removeCallbacks(watchdog)
        handler.postDelayed(watchdog, RESTART_INTERVAL_MS)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(watchdog)
        try {
            stopForegroundCompat()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "问象通知同步",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.setSound(null, null)
        channel.enableVibration(false)
        channel.setShowBadge(false)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle("问象通知已开启")
            .setContentText("后台保持连接，确保任务完成时推送")
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_LOW)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        return builder.build()
    }

    companion object {
        private const val CHANNEL_ID = "wenxiang_sync"
        private const val NOTIFICATION_ID = 8788
        // Android 14 caps a single dataSync startForeground call at ~6 h.
        // Restart 1 h early to stay safely under the limit.
        private const val RESTART_INTERVAL_MS: Long = 5 * 60 * 60 * 1000L
    }
}
