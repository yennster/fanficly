package io.github.yennster.fanficly.subscriptions

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.github.yennster.fanficly.R

/**
 * Local notifications for the subscription poller — the Android counterpart of
 * the iOS `UNUserNotificationCenter` wiring in `SubscriptionPoller`. Everything
 * stays on-device; tapping a notification deep-links into the work via the
 * existing AO3-URL `VIEW` intent filter (scoped to this app's package).
 */
object Notifications {
    const val CHANNEL_ID = "new_chapters"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "New chapters",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply { description = "Alerts when a followed work gets a new chapter." }
            context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    /** @param authorKey the stable username (DB primary key) for the notification
     *   id, so two authors with the same [authorName] don't collide. */
    fun postNewWork(
        context: Context,
        authorKey: String,
        authorName: String,
        newWorks: List<io.github.yennster.fanficly.model.WorkSummary>,
    ) {
        if (!canPost(context) || newWorks.isEmpty()) return
        ensureChannel(context)
        val first = newWorks.first()
        val body = if (newWorks.size == 1) "New work: ${first.title}" else "${newWorks.size} new works posted"
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://archiveofourown.org/works/${first.id}"))
            .setPackage(context.packageName)
        val id = "author-$authorKey".hashCode()
        val pending = PendingIntent.getActivity(
            context, id, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(authorName)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        NotificationManagerCompat.from(context).notify(id, notification)
    }

    fun postNewChapter(context: Context, workId: Int, title: String, oldCount: Int, newCount: Int) {
        if (!canPost(context)) return
        ensureChannel(context)
        val added = newCount - oldCount
        val body = if (added == 1) "1 new chapter posted ($newCount total)"
        else "$added new chapters posted ($newCount total)"

        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://archiveofourown.org/works/$workId"))
            .setPackage(context.packageName)
        val pending = PendingIntent.getActivity(
            context, workId, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        // notify id = workId so repeat polls of the same work coalesce.
        NotificationManagerCompat.from(context).notify(workId, notification)
    }

    private fun canPost(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
}
