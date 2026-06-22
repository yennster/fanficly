package io.github.yennster.fanficly.subscriptions

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.github.yennster.fanficly.FanficlyApplication
import java.util.concurrent.TimeUnit

/**
 * Background "new chapter" poll — the Android counterpart of the iOS
 * `BackgroundRefresh` BGAppRefreshTask. WorkManager runs it on its own schedule
 * (~every 6h, only when networked); each run checks locally-followed works for
 * new chapters and notifies. Reuses the app's single throttled [AO3Client].
 */
class SubscriptionWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val container = (applicationContext as FanficlyApplication).container
        val poller = SubscriptionPoller(applicationContext, container.ao3Client, container.libraryRepository)
        return try {
            poller.runFullPoll()
            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }

    companion object {
        private const val UNIQUE_NAME = "subscription-poll"

        /** Enqueue the periodic poll (idempotent — KEEP preserves an existing one). */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SubscriptionWorker>(6, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                )
                .build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(UNIQUE_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
