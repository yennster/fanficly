package io.github.yennster.fanficly

import android.app.Application

class FanficlyApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        val versionName = runCatching {
            packageManager.getPackageInfo(packageName, 0).versionName
        }.getOrNull() ?: "1.0.0"
        container = AppContainer(this, versionName)
    }
}
