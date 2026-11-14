package cn.wenxiang.wenxiang

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/** One continuous PCM track per call playback epoch. Never blocks the UI on audio writes. */
class CallPcmOutput(messenger: BinaryMessenger) {
    private val thread = HandlerThread("call-pcm").apply { start() }
    private val worker = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "cn.wenxiang.wenxiang/call_pcm")
    private var track: AudioTrack? = null
    private var token = ""
    private var rate = 24000
    private var accepted = 0L
    private var written = 0L
    private var offset = 0
    private var fault: String? = null
    private val queue = ArrayDeque<ByteArray>()
    private val pump = object : Runnable {
        override fun run() {
            val output = track ?: return
            try {
                while (queue.isNotEmpty()) {
                    val bytes = queue.first
                    val count = output.write(bytes, offset, bytes.size - offset, AudioTrack.WRITE_NON_BLOCKING)
                    check(count >= 0) { "PCM write failed: $count" }
                    if (count == 0) break
                    offset += count
                    written += count / 2
                    if (offset == bytes.size) { queue.removeFirst(); offset = 0 }
                }
                if (queue.isNotEmpty()) worker.postDelayed(this, 10)
            } catch (err: Exception) {
                fault = err.message ?: "PCM playback failed"
                queue.clear()
            }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            worker.post {
                try {
                    val requested = call.argument<String>("token") ?: ""
                    val value: Any? = when (call.method) {
                        "open" -> {
                            releaseTrack()
                            token = requested
                            rate = call.argument<Int>("rate") ?: 24000
                            require(rate in 8000..48000)
                            val minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
                            check(minimum > 0) { "PCM output unavailable" }
                            track = AudioTrack.Builder()
                                .setAudioAttributes(AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                                .setAudioFormat(AudioFormat.Builder().setSampleRate(rate)
                                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                                .setBufferSizeInBytes(maxOf(minimum, rate / 5 * 2))
                                .setTransferMode(AudioTrack.MODE_STREAM).build()
                            check(track!!.state == AudioTrack.STATE_INITIALIZED)
                            if (Build.VERSION.SDK_INT >= 31) track!!.setStartThresholdInFrames(1)
                            track!!.play()
                            null
                        }
                        "push" -> {
                            check(requested == token && track != null) { "PCM session expired" }
                            check(fault == null) { fault!! }
                            val bytes = call.argument<ByteArray>("pcm") ?: ByteArray(0)
                            require(bytes.size % 2 == 0)
                            val head = headFrames()
                            check(accepted - head + bytes.size / 2 <= rate * 120L) { "PCM queue overflow" }
                            val start = accepted
                            accepted += bytes.size / 2
                            if (bytes.isNotEmpty()) queue.addLast(bytes)
                            worker.removeCallbacks(pump)
                            pump.run()
                            start
                        }
                        "status" -> {
                            check(fault == null || requested != token) { fault!! }
                            if (requested != token) mapOf("head" to 0L, "remaining" to 0L)
                            else mapOf("head" to headFrames(), "remaining" to maxOf(0L, accepted - headFrames()))
                        }
                        "stop" -> { if (requested == token) releaseTrack(); null }
                        else -> throw IllegalArgumentException("Unknown PCM command")
                    }
                    main.post { result.success(value) }
                } catch (err: Exception) {
                    main.post { result.error("call_pcm", err.message, null) }
                }
            }
        }
    }

    private fun headFrames(): Long = track?.playbackHeadPosition?.toLong()?.and(0xffffffffL) ?: 0L

    private fun releaseTrack() {
        worker.removeCallbacks(pump)
        val old = track
        track = null
        queue.clear()
        offset = 0
        accepted = 0
        written = 0
        fault = null
        token = ""
        try { old?.pause(); old?.flush() } finally { old?.release() }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.post { try { releaseTrack() } finally { thread.quitSafely() } }
    }
}
