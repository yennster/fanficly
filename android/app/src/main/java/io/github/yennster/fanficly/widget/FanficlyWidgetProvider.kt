package io.github.yennster.fanficly.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import io.github.yennster.fanficly.R
import kotlin.math.roundToInt

/**
 * Home-screen widget showing the last-read story (title, author, progress) — the
 * Android port of the iOS `FanficlyWidget`. Tapping it deep-links into the work
 * via the existing AO3-URL `VIEW` intent (scoped to this app), so the reader
 * reopens and restores the saved reading position (i.e. "resume").
 */
class FanficlyWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        val views = buildViews(context)
        appWidgetIds.forEach { manager.updateAppWidget(it, views) }
    }

    companion object {
        /** Rebuild + push the widget to every placed instance (no-op if none). */
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, FanficlyWidgetProvider::class.java))
            if (ids.isNotEmpty()) manager.updateAppWidget(ids, buildViews(context))
        }

        private fun buildViews(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_last_read)
            val snap = WidgetProgressStore(context).load()
            if (snap == null) {
                views.setTextViewText(R.id.widget_title, "No recent story")
                views.setTextViewText(R.id.widget_author, "Open the app to read")
                views.setViewVisibility(R.id.widget_percent, View.GONE)
                views.setTextViewText(R.id.widget_cta, "Open the app to start")
                views.setViewVisibility(R.id.widget_progress, View.GONE)
                views.setOnClickPendingIntent(R.id.widget_root, launchAppIntent(context))
            } else {
                val pct = (snap.progress.coerceIn(0f, 1f) * 100).roundToInt()
                views.setTextViewText(R.id.widget_title, snap.title)
                views.setTextViewText(R.id.widget_author, snap.author)
                views.setTextViewText(R.id.widget_percent, "$pct%")
                views.setViewVisibility(R.id.widget_percent, View.VISIBLE)
                views.setTextViewText(R.id.widget_cta, "Continue reading")
                views.setViewVisibility(R.id.widget_progress, View.VISIBLE)
                views.setProgressBar(R.id.widget_progress, 100, pct, false)
                views.setOnClickPendingIntent(R.id.widget_root, resumeIntent(context, snap.id))
            }
            return views
        }

        /** Open the work (and restore reading position) via the AO3-URL VIEW filter. */
        private fun resumeIntent(context: Context, workId: Int): PendingIntent {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://archiveofourown.org/works/$workId"))
                .setPackage(context.packageName)
            return PendingIntent.getActivity(
                context, workId, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        private fun launchAppIntent(context: Context): PendingIntent {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(Intent.ACTION_MAIN)
            return PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
    }
}
