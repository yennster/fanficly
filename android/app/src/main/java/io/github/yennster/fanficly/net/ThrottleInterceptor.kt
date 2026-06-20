package io.github.yennster.fanficly.net

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Enforces a minimum interval between AO3 requests — the Kotlin counterpart of
 * iOS `ThrottleActor` (1 req/sec). AO3 is generous to good citizens and hostile
 * to bad ones, so every request goes through here. Implemented as a blocking
 * OkHttp interceptor (OkHttp dispatches on a background pool), serialized with a
 * lock so concurrent calls queue rather than burst.
 */
class ThrottleInterceptor(private val minimumIntervalMs: Long = 1_000L) : Interceptor {
    private val lock = Any()
    @Volatile private var nextEarliest: Long = 0L

    override fun intercept(chain: Interceptor.Chain): Response {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            if (now < nextEarliest) {
                try {
                    Thread.sleep(nextEarliest - now)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
            nextEarliest = System.currentTimeMillis() + minimumIntervalMs
        }
        return chain.proceed(chain.request())
    }
}

/**
 * A coroutine-friendly throttle for non-OkHttp call sites (kept for parity with
 * the iOS actor API; the network path uses [ThrottleInterceptor]).
 */
class CoroutineThrottle(private val minimumIntervalMs: Long = 1_000L) {
    private val mutex = Mutex()
    private var nextEarliest = 0L

    suspend fun wait() = mutex.withLock {
        val now = System.currentTimeMillis()
        if (now < nextEarliest) {
            kotlinx.coroutines.delay(nextEarliest - now)
        }
        nextEarliest = System.currentTimeMillis() + minimumIntervalMs
    }
}
