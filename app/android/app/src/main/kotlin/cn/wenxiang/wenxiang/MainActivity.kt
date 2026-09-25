package cn.wenxiang.wenxiang

import android.content.Intent
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "cn.wenxiang.wenxiang/audio_route",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "resetToMediaPlayback" -> {
                    val am = getSystemService(AUDIO_SERVICE) as AudioManager
                    try {
                        am.stopBluetoothSco()
                        am.isBluetoothScoOn = false
                    } catch (_: Exception) {
                    }
                    am.mode = AudioManager.MODE_NORMAL
                    am.isSpeakerphoneOn = false
                    volumeControlStream = AudioManager.STREAM_MUSIC
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "cn.wenxiang.wenxiang/background_work",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val mic = call.argument<Boolean>("microphone") == true
                    val intent = Intent(this, PlaybackService::class.java)
                        .putExtra("microphone", mic)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, PlaybackService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
