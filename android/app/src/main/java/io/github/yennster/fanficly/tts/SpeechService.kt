package io.github.yennster.fanficly.tts

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

/**
 * Foreground service that keeps "Listen" narration alive in the background and
 * shows playback controls — the Android counterpart of the iOS audio
 * `UIBackgroundMode` + lock-screen Now Playing wiring. It owns no audio itself;
 * [SpeechController] drives the engine, and this service mirrors its [state]
 * into an ongoing notification (play/pause + stop) and self-stops when narration
 * ends. (A full MediaSession/MediaStyle treatment would need androidx.media; a
 * plain action notification keeps the app dependency-light.)
 */
class SpeechService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val controller by lazy { (application as FanficlyApplication).container.speechController }
    private var started = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        controller.state
            .onEach { state ->
                if (!state.isActive) {
                    stopForegroundCompat()
                    stopSelf()
                } else {
                    val notification = buildNotification(state)
                    if (!started) {
                        startForegroundCompat(notification)
                        started = true
                    } else {
                        getSystemService(NotificationManager::class.java)?.notify(NOTIF_ID, notification)
                    }
                }
            }
            .launchIn(scope)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> controller.togglePlayPause()
            ACTION_STOP -> controller.stop()
        }
        // Guarantee startForeground within the allowed window even if the state
        // flow hasn't emitted yet.
        if (!started) {
            startForegroundCompat(buildNotification(controller.state.value))
            started = true
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun buildNotification(state: SpeechState): android.app.Notification {
        val toggle = action(
            if (state.isPlaying) "Pause" else "Play",
            ACTION_TOGGLE,
        )
        val stop = action("Stop", ACTION_STOP)
        val content = buildString {
            if (state.chapterLabel.isNotEmpty()) append(state.chapterLabel)
            if (state.spokenCount > 0) {
                if (isNotEmpty()) append(" · ")
                append("¶ ${state.spokenPosition} / ${state.spokenCount}")
            }
        }
        val tap = packageManager.getLaunchIntentForPackage(packageName)
        val tapPending = PendingIntent.getActivity(
            this, 0, tap ?: Intent(),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(state.workTitle.ifEmpty { "Listening" })
            .setContentText(content)
            // Keep the notification pinned for the whole session (playing OR
            // paused) so its transport controls survive a pause.
            .setOngoing(state.isActive)
            .setOnlyAlertOnce(true)
            .setContentIntent(tapPending)
            .addAction(0, if (state.isPlaying) "Pause" else "Play", toggle)
            .addAction(0, "Stop", stop)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    private fun action(name: String, actionId: String): PendingIntent {
        val intent = Intent(this, SpeechService::class.java).setAction(actionId)
        return PendingIntent.getService(
            this, actionId.hashCode(), intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun startForegroundCompat(notification: android.app.Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIF_ID, notification)
        }
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Listen (text-to-speech)", NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Playback controls while a story is being read aloud." }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    companion object {
        private const val CHANNEL_ID = "tts_playback"
        private const val NOTIF_ID = 42_001
        const val ACTION_TOGGLE = "io.github.yennster.fanficly.tts.TOGGLE"
        const val ACTION_STOP = "io.github.yennster.fanficly.tts.STOP"
    }
}
