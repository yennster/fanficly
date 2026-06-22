package io.github.yennster.fanficly.net

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * Keeps AO3's session cookies and persists them to encrypted storage, so the
 * login survives app restarts — the Android counterpart of iOS storing the
 * session cookie in the Keychain (`CredentialStore`). The session cookie is the
 * only secret the app persists; it lives in EncryptedSharedPreferences and is
 * excluded from cloud backup (see backup_rules.xml).
 *
 * NOTE: depends on `androidx.security:security-crypto`. If you prefer to drop
 * that dependency, swap [securePrefs] for ordinary SharedPreferences — the
 * privacy trade-off is documented in ANDROID_PUBLISHING.md.
 */
class PersistentCookieJar(context: Context) : CookieJar {
    private val appContext = context.applicationContext
    private val prefs by lazy {
        val masterKey = MasterKey.Builder(appContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            appContext,
            "fanficly_secure_prefs",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    // In-memory cache keyed by cookie name; AO3 sets a small, fixed set.
    private val store = mutableMapOf<String, Cookie>()

    init {
        loadFromDisk()
    }

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        var changed = false
        for (cookie in cookies) {
            if (cookie.expiresAt < System.currentTimeMillis()) {
                if (store.remove(cookie.name) != null) changed = true
            } else {
                store[cookie.name] = cookie
                changed = true
            }
        }
        if (changed) persist()
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        val valid = store.values.filter { it.expiresAt > now && it.matches(url) }
        return valid
    }

    @Synchronized
    fun clear() {
        store.clear()
        prefs.edit().clear().apply()
    }

    @Synchronized
    fun hasSession(): Boolean =
        store.keys.any { it.contains("user_credentials") || it.contains("remember_user_token") }

    /** The logged-in username, persisted alongside the session so it survives a
     *  process restart (the cookie does, but the in-memory username doesn't). */
    fun savedUsername(): String? = prefs.getString(KEY_USERNAME, null)

    fun saveUsername(name: String) {
        prefs.edit().putString(KEY_USERNAME, name).apply()
    }

    private fun persist() {
        val serialized = store.values.map { it.toString() }.toSet()
        prefs.edit().putStringSet(KEY_COOKIES, serialized).apply()
    }

    private fun loadFromDisk() {
        val base = AO3Endpoints.BASE
        prefs.getStringSet(KEY_COOKIES, emptySet())?.forEach { raw ->
            Cookie.parse(base, raw)?.let { store[it.name] = it }
        }
    }

    private companion object {
        const val KEY_COOKIES = "ao3_cookies"
        const val KEY_USERNAME = "ao3_username"
    }
}
