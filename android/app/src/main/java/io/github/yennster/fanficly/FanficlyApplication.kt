package io.github.yennster.fanficly

import android.app.Application
import io.github.yennster.fanficly.subscriptions.Notifications
import io.github.yennster.fanficly.subscriptions.SubscriptionWorker

class FanficlyApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        val versionName = runCatching {
            packageManager.getPackageInfo(packageName, 0).versionName
        }.getOrNull() ?: "1.0.0"
        container = AppContainer(this, versionName)

        // Background "new chapter" poller for locally-followed works.
        Notifications.ensureChannel(this)
        SubscriptionWorker.schedule(this)
    }
}
