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
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

/// Keeps the process alive and, while the activity is not visible, pulls
/// unread inbox items and posts them as system notifications. The Flutter
/// isolate is frozen in the background on many phones, so the WebSocket
/// listener does not run until the user comes back.
class SyncService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val polling = AtomicBoolean(false)
    private val poll: Runnable = object : Runnable {
        override fun run() {
            pollInbox()
            handler.postDelayed(this, POLL_MS)
        }
    }
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
        ensureChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val url = intent?.getStringExtra("baseUrl").orEmpty().trim()
        val key = intent?.getStringExtra("apiKey").orEmpty().trim()
        if (url.isNotEmpty()) baseUrl = url
        if (key.isNotEmpty()) apiKey = key
        val notification = buildOngoing()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                ONGOING_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(ONGOING_ID, notification)
        }
        handler.removeCallbacks(watchdog)
        handler.postDelayed(watchdog, RESTART_INTERVAL_MS)
        handler.removeCallbacks(poll)
        handler.post(poll)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(watchdog)
        handler.removeCallbacks(poll)
        try {
            stopForegroundCompat()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    private fun pollInbox() {
        if (activityVisible) return
        val root = baseUrl.trimEnd('/')
        val key = apiKey
        if (root.isEmpty() || key.isEmpty()) return
        if (!polling.compareAndSet(false, true)) return
        Thread {
            try {
                val body = http(root, key, "GET", "/v1/inbox", null) ?: return@Thread
                val items = JSONObject(body).optJSONArray("items") ?: return@Thread
                for (i in 0 until items.length()) {
                    val item = items.optJSONObject(i) ?: continue
                    if (item.optBoolean("read")) continue
                    showInbox(item)
                }
            } catch (_: Exception) {
            } finally {
                polling.set(false)
            }
        }.start()
    }

    private fun showInbox(item: JSONObject) {
        val id = item.optString("id")
        val title = item.optString("title").ifBlank { "问象" }
        val text = item.optString("body")
        if (text.isBlank()) return
        val manager = getSystemService(NotificationManager::class.java)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, INBOX_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setAutoCancel(true)
            .setPriority(Notification.PRIORITY_HIGH)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        manager.notify(noteId(id), builder.build())
    }

    private fun http(
        root: String,
        key: String,
        method: String,
        path: String,
        payload: String?,
    ): String? {
        val conn = URL(root + path).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 8000
        conn.readTimeout = 8000
        conn.setRequestProperty("X-Wenxiang-Key", key)
        if (payload != null) {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(payload.toByteArray()) }
        }
        val code = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
        if (code !in 200..299) return null
        return text
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val ongoing = NotificationChannel(
            ONGOING_CHANNEL_ID,
            "问象通知同步",
            NotificationManager.IMPORTANCE_LOW,
        )
        ongoing.setSound(null, null)
        ongoing.enableVibration(false)
        ongoing.setShowBadge(false)
        manager.createNotificationChannel(ongoing)
        val inbox = NotificationChannel(
            INBOX_CHANNEL_ID,
            "问书通知",
            NotificationManager.IMPORTANCE_HIGH,
        )
        inbox.setShowBadge(true)
        manager.createNotificationChannel(inbox)
    }

    private fun buildOngoing(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, ONGOING_CHANNEL_ID)
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
        @Volatile
        var activityVisible: Boolean = true

        @Volatile
        var baseUrl: String = ""

        @Volatile
        var apiKey: String = ""

        private const val ONGOING_CHANNEL_ID = "wenxiang_sync"
        private const val INBOX_CHANNEL_ID = "wenxiang_inbox"
        private const val ONGOING_ID = 8788
        private const val POLL_MS = 4_000L
        private const val RESTART_INTERVAL_MS: Long = 5 * 60 * 60 * 1000L

        private fun noteId(id: String): Int {
            val h = id.hashCode() and 0x7fffffff
            return if (h == 0 || h == ONGOING_ID) 1 else h
        }
    }
}
