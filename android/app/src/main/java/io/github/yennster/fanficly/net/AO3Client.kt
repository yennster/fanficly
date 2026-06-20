package io.github.yennster.fanficly.net

import android.content.Context
import io.github.yennster.fanficly.model.AO3Exception
import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.AutocompleteField
import io.github.yennster.fanficly.model.ExportFormat
import io.github.yennster.fanficly.model.SearchResults
import io.github.yennster.fanficly.model.WorkMetadata
import io.github.yennster.fanficly.model.WorkPayload
import io.github.yennster.fanficly.net.parse.LoginParser
import io.github.yennster.fanficly.net.parse.SearchResultsParser
import io.github.yennster.fanficly.net.parse.WorkPageParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * The only seam to the network — the Kotlin port of iOS `AO3ClientProtocol` +
 * the live `AO3Client` actor. UI never touches OkHttp directly; everything goes
 * through this interface so it can be swapped for [MockAO3Client] in previews
 * and tests. All requests run on [Dispatchers.IO] and pass through the
 * [ThrottleInterceptor] (1 req/sec).
 */
interface AO3Client {
    suspend fun login(username: String, password: String)
    fun logout()
    fun currentUsername(): String?
    fun isLoggedIn(): Boolean
    suspend fun search(filters: AO3SearchFilters, page: Int): SearchResults
    suspend fun fetchAuthorWorks(username: String, page: Int): SearchResults
    suspend fun fetchBookmarks(username: String, page: Int): SearchResults
    suspend fun fetchWork(id: Int): WorkPayload
    suspend fun fetchWorkMetadata(id: Int): WorkMetadata
    suspend fun autocomplete(field: AutocompleteField, term: String): List<String>
    suspend fun downloadEpub(workId: Int, cacheDir: File): File
    suspend fun exportWork(workId: Int, format: ExportFormat, filename: String, cacheDir: File): File
    suspend fun subscribeToWork(workId: Int)
}

class LiveAO3Client(
    context: Context,
    private val versionName: String,
) : AO3Client {

    private val cookieJar = PersistentCookieJar(context)
    private var cachedUsername: String? = null

    private val userAgent = "Fanficly/$versionName (+github.com/yennster/fanficly)"

    private val client: OkHttpClient = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .addInterceptor(ThrottleInterceptor(1_000L))
        .addInterceptor { chain ->
            // The AO3 ops team identifies us by this UA; keep it honest.
            val req = chain.request().newBuilder()
                .header("User-Agent", userAgent)
                .header("Accept-Language", "en-US,en;q=0.9")
                .apply {
                    if (chain.request().header("Accept") == null) {
                        header("Accept", "text/html,application/xhtml+xml")
                    }
                }
                .build()
            chain.proceed(req)
        }
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(45, TimeUnit.SECONDS)
        .build()

    override suspend fun login(username: String, password: String) = withContext(Dispatchers.IO) {
        val loginUrl = AO3Endpoints.login()
        val formHtml = getString(loginUrl)
        val token = LoginParser.authenticityToken(formHtml)
            ?: throw AO3Exception.ParseFailed("authenticity_token not found")

        val body = FormBody.Builder()
            .add("utf8", "✓")
            .add("authenticity_token", token)
            .add("user[login]", username)
            .add("user[password]", password)
            .add("user[remember_me]", "1")
            .add("commit", "Log in")
            .build()
        val request = Request.Builder()
            .url(loginUrl)
            .header("Origin", AO3Endpoints.BASE.toString().trimEnd('/'))
            .header("Referer", loginUrl.toString())
            .post(body)
            .build()
        val respHtml = executeString(request)

        LoginParser.currentUsername(respHtml)?.let { cachedUsername = it; return@withContext }
        LoginParser.detectLoginFailure(respHtml)?.let { throw AO3Exception.LoginFailed(it) }
        if (LoginParser.hasLoginForm(respHtml)) {
            throw AO3Exception.LoginFailed("Incorrect username or password.")
        }
        if (cookieJar.hasSession()) { cachedUsername = username; return@withContext }
        throw AO3Exception.LoginFailed("Couldn't confirm login. Please try again.")
    }

    override fun logout() {
        cookieJar.clear()
        cachedUsername = null
    }

    override fun currentUsername(): String? = cachedUsername
    override fun isLoggedIn(): Boolean = cachedUsername != null || cookieJar.hasSession()

    override suspend fun search(filters: AO3SearchFilters, page: Int): SearchResults =
        withContext(Dispatchers.IO) {
            SearchResultsParser.parse(getString(AO3Endpoints.search(filters, page)))
        }

    override suspend fun fetchAuthorWorks(username: String, page: Int): SearchResults =
        withContext(Dispatchers.IO) {
            // Author works pages reuse the search blurb markup.
            SearchResultsParser.parse(getString(AO3Endpoints.authorWorks(username, page)))
        }

    override suspend fun fetchBookmarks(username: String, page: Int): SearchResults =
        withContext(Dispatchers.IO) {
            SearchResultsParser.parse(
                getString(AO3Endpoints.userBookmarks(username, page)),
                blurbSelector = "li.bookmark.blurb",
            )
        }

    override suspend fun fetchWork(id: Int): WorkPayload = withContext(Dispatchers.IO) {
        WorkPageParser.parse(getString(AO3Endpoints.work(id)), id)
    }

    override suspend fun fetchWorkMetadata(id: Int): WorkMetadata = withContext(Dispatchers.IO) {
        WorkPageParser.parseMetadata(getString(AO3Endpoints.work(id)), id)
    }

    override suspend fun autocomplete(field: AutocompleteField, term: String): List<String> =
        withContext(Dispatchers.IO) {
            if (term.isBlank()) return@withContext emptyList()
            val request = Request.Builder()
                .url(AO3Endpoints.autocomplete(field, term.trim()))
                .header("Accept", "application/json, text/javascript, */*; q=0.01")
                .header("X-Requested-With", "XMLHttpRequest")
                .build()
            val json = executeString(request)
            runCatching {
                val arr = JSONArray(json)
                (0 until arr.length()).mapNotNull { i ->
                    val o = arr.optJSONObject(i) ?: return@mapNotNull null
                    o.optString("name").ifEmpty { o.optString("id").ifEmpty { null } }
                }
            }.getOrDefault(emptyList())
        }

    override suspend fun downloadEpub(workId: Int, cacheDir: File): File =
        download(AO3Endpoints.epub(workId), File(File(cacheDir, "library").apply { mkdirs() }, "$workId.epub"))

    override suspend fun exportWork(workId: Int, format: ExportFormat, filename: String, cacheDir: File): File {
        val dir = File(cacheDir, "exports").apply { mkdirs() }
        val safe = sanitizeFilename(filename.ifEmpty { "work-$workId" })
        return download(AO3Endpoints.download(workId, format), File(dir, "$safe.${format.ext}"))
    }

    override suspend fun subscribeToWork(workId: Int) = withContext(Dispatchers.IO) {
        val pageUrl = AO3Endpoints.work(workId)
        val token = LoginParser.authenticityToken(getString(pageUrl))
            ?: throw AO3Exception.ParseFailed("authenticity_token not found on work page")
        val body = FormBody.Builder()
            .add("authenticity_token", token)
            .add("subscription[subscribable_id]", workId.toString())
            .add("subscription[subscribable_type]", "Work")
            .build()
        val request = Request.Builder()
            .url(AO3Endpoints.workSubscriptions(workId))
            .header("Referer", pageUrl.toString())
            .header("Origin", AO3Endpoints.BASE.toString().trimEnd('/'))
            .header("X-CSRF-Token", token)
            .post(body)
            .build()
        client.newCall(request).execute().use { resp ->
            if (resp.code >= 400 && resp.code != 422) throw AO3Exception.Http(resp.code)
        }
    }

    // MARK: - Request helpers

    private fun getString(url: HttpUrl): String =
        executeString(Request.Builder().url(url).build())

    private fun executeString(request: Request): String {
        try {
            client.newCall(request).execute().use { resp ->
                when (resp.code) {
                    in 200..299, 302 -> {}
                    401, 403 -> throw AO3Exception.Unauthorized
                    429 -> throw AO3Exception.RateLimited
                    else -> throw AO3Exception.Http(resp.code)
                }
                return resp.body?.string() ?: throw AO3Exception.ParseFailed("Empty response")
            }
        } catch (e: AO3Exception) {
            throw e
        } catch (e: Exception) {
            throw AO3Exception.Network(e.message ?: "Network error")
        }
    }

    private suspend fun download(url: HttpUrl, dest: File): File = withContext(Dispatchers.IO) {
        try {
            client.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                if (resp.code !in 200..299) throw AO3Exception.Http(resp.code)
                val bytes = resp.body?.bytes() ?: throw AO3Exception.ParseFailed("Empty download")
                dest.writeBytes(bytes)
            }
            dest
        } catch (e: AO3Exception) {
            throw e
        } catch (e: Exception) {
            throw AO3Exception.Network(e.message ?: "Download error")
        }
    }

    private fun sanitizeFilename(name: String): String {
        val cleaned = name.map { if (it in "/\\?%*|\"<>:") '-' else it }.joinToString("")
        return cleaned.take(80).trim()
    }
}
