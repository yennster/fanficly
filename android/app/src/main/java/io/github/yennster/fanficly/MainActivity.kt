package io.github.yennster.fanficly

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Subscriptions
import androidx.compose.material.icons.filled.Whatshot
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import io.github.yennster.fanficly.model.PopularKind
import io.github.yennster.fanficly.net.parse.SearchResultsParser
import io.github.yennster.fanficly.ui.browse.BrowseScreen
import io.github.yennster.fanficly.ui.browse.CategoryFandomsScreen
import io.github.yennster.fanficly.ui.browse.FandomWorksScreen
import io.github.yennster.fanficly.ui.authors.AuthorWorksScreen
import io.github.yennster.fanficly.ui.authors.FollowedAuthorsScreen
import io.github.yennster.fanficly.ui.bookmarks.BookmarksScreen
import io.github.yennster.fanficly.ui.browse.PopularScreen
import io.github.yennster.fanficly.ui.comments.CommentsScreen
import io.github.yennster.fanficly.ui.library.LibraryScreen
import io.github.yennster.fanficly.ui.subscriptions.SubscriptionsScreen
import io.github.yennster.fanficly.ui.search.SearchScreen
import io.github.yennster.fanficly.ui.settings.SettingsScreen
import io.github.yennster.fanficly.ui.theme.FanficlyTheme
import io.github.yennster.fanficly.ui.work.WorkScreen

class MainActivity : ComponentActivity() {
    // A deep-link / widget / notification tap that arrives while the app is
    // already running (singleTop reuses this activity rather than stacking a
    // second one). The composable observes it and routes to the work.
    private val pendingWorkId = mutableStateOf<Int?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val deepLinkWorkId = workIdFromIntent(intent)
        setContent {
            FanficlyTheme {
                FanficlyApp(initialWorkId = deepLinkWorkId, pendingWorkId = pendingWorkId)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        workIdFromIntent(intent)?.let { pendingWorkId.value = it }
    }

    /** Extract an AO3 work id from a VIEW (deep link) or SEND (share) intent. */
    private fun workIdFromIntent(intent: Intent?): Int? {
        intent ?: return null
        val candidate = when (intent.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        } ?: return null
        return SearchResultsParser.workId(candidate)
    }
}

private enum class Tab(val route: String, val label: String, val icon: ImageVector) {
    SEARCH("search", "Search", Icons.Filled.Search),
    BROWSE("browse", "Browse", Icons.Filled.Explore),
    POPULAR("popular", "Popular", Icons.Filled.Whatshot),
    LIBRARY("library", "Library", Icons.Filled.Book),
    SETTINGS("settings", "Settings", Icons.Filled.Settings),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FanficlyApp(initialWorkId: Int?, pendingWorkId: MutableState<Int?>) {
    // Ask for notification permission (Android 13+) so the subscription poller's
    // "new chapter" alerts can show. Declined is fine — the poll still runs and
    // just won't surface a notification.
    val context = LocalContext.current
    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            permLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    val navController = rememberNavController()

    // Warm taps (widget / notification / share while the app is already running):
    // route to the work and clear, so singleTop doesn't drop the new intent.
    LaunchedEffect(pendingWorkId.value) {
        pendingWorkId.value?.let { id ->
            navController.navigate("work/$id")
            pendingWorkId.value = null
        }
    }

    val backStack by navController.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    // Bottom nav only on the top-level tab destinations; pushed detail screens
    // (a work, a category's fandoms, a fandom/tag's works) hide it.
    val isTopLevel = currentRoute in Tab.entries.map { it.route }

    Scaffold(
        bottomBar = {
            if (isTopLevel) {
                NavigationBar {
                    Tab.entries.forEach { tab ->
                        NavigationBarItem(
                            selected = currentRoute == tab.route,
                            onClick = {
                                navController.navigate(tab.route) {
                                    popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = { Icon(tab.icon, contentDescription = tab.label) },
                            label = { Text(tab.label) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = if (initialWorkId != null) "work/$initialWorkId" else Tab.SEARCH.route,
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            composable(Tab.SEARCH.route) {
                TitledScreen("Search") { SearchScreen(onOpenWork = { navController.navigate("work/$it") }) }
            }
            composable(Tab.BROWSE.route) {
                TitledScreen("Browse") {
                    BrowseScreen(onOpenCategory = { navController.navigate("browse/category/$it") })
                }
            }
            composable(Tab.POPULAR.route) {
                TitledScreen("Popular") {
                    PopularScreen(onOpenTag = { kind, name ->
                        val field = when (kind) {
                            PopularKind.FANDOM -> "fandom"
                            PopularKind.SHIP -> "relationship"
                            PopularKind.CHARACTER -> "character"
                        }
                        navController.navigate(worksRoute(field, name, name, "kudos_count"))
                    })
                }
            }
            composable(Tab.LIBRARY.route) {
                TitledScreen("Library", actions = {
                    IconButton(onClick = { navController.navigate("authors") }) {
                        Icon(Icons.Filled.Group, contentDescription = "Followed authors")
                    }
                    IconButton(onClick = { navController.navigate("bookmarks") }) {
                        Icon(Icons.Filled.BookmarkBorder, contentDescription = "Bookmarks")
                    }
                    IconButton(onClick = { navController.navigate("subscriptions") }) {
                        Icon(Icons.Filled.Subscriptions, contentDescription = "Subscriptions")
                    }
                }) { LibraryScreen(onOpenWork = { navController.navigate("work/$it") }) }
            }
            composable(Tab.SETTINGS.route) {
                TitledScreen("Settings") { SettingsScreen() }
            }
            composable("bookmarks") {
                BookmarksScreen(
                    onBack = { navController.popBackStack() },
                    onOpenWork = { navController.navigate("work/$it") },
                )
            }
            composable("subscriptions") {
                SubscriptionsScreen(
                    onBack = { navController.popBackStack() },
                    onOpenWork = { navController.navigate("work/$it") },
                )
            }
            composable(
                route = "browse/category/{categoryId}",
                arguments = listOf(navArgument("categoryId") { type = NavType.StringType }),
            ) { entry ->
                CategoryFandomsScreen(
                    categoryId = entry.arguments?.getString("categoryId") ?: "",
                    onBack = { navController.popBackStack() },
                    onOpenFandom = { canonical, display ->
                        navController.navigate(worksRoute("fandom", canonical, display, "revised_at"))
                    },
                )
            }
            composable(
                route = "works?field={field}&name={name}&title={title}&sort={sort}",
                arguments = listOf(
                    navArgument("field") { type = NavType.StringType; defaultValue = "fandom" },
                    navArgument("name") { type = NavType.StringType; defaultValue = "" },
                    navArgument("title") { type = NavType.StringType; defaultValue = "" },
                    navArgument("sort") { type = NavType.StringType; defaultValue = "revised_at" },
                ),
            ) { entry ->
                val a = entry.arguments
                FandomWorksScreen(
                    field = a?.getString("field") ?: "fandom",
                    name = a?.getString("name") ?: "",
                    title = a?.getString("title") ?: "",
                    sort = a?.getString("sort") ?: "revised_at",
                    onBack = { navController.popBackStack() },
                    onOpenWork = { navController.navigate("work/$it") },
                )
            }
            composable(
                route = "work/{workId}",
                arguments = listOf(navArgument("workId") { type = NavType.IntType }),
            ) { entry ->
                val id = entry.arguments?.getInt("workId") ?: return@composable
                WorkScreen(
                    workId = id,
                    onBack = { if (!navController.popBackStack()) navController.navigate(Tab.SEARCH.route) },
                    onShowSettings = { navController.navigate(Tab.SETTINGS.route) },
                    onShowComments = { navController.navigate("comments/$it") },
                    onOpenAuthor = { username, name -> navController.navigate(authorRoute(username, name)) },
                )
            }
            composable("authors") {
                FollowedAuthorsScreen(
                    onBack = { navController.popBackStack() },
                    onOpenAuthor = { username, name -> navController.navigate(authorRoute(username, name)) },
                )
            }
            composable(
                route = "author?username={username}&name={name}",
                arguments = listOf(
                    navArgument("username") { type = NavType.StringType; defaultValue = "" },
                    navArgument("name") { type = NavType.StringType; defaultValue = "" },
                ),
            ) { entry ->
                AuthorWorksScreen(
                    username = entry.arguments?.getString("username") ?: "",
                    displayName = entry.arguments?.getString("name") ?: "",
                    onBack = { navController.popBackStack() },
                    onOpenWork = { navController.navigate("work/$it") },
                )
            }
            composable(
                route = "comments/{workId}",
                arguments = listOf(navArgument("workId") { type = NavType.IntType }),
            ) { entry ->
                val id = entry.arguments?.getInt("workId") ?: return@composable
                CommentsScreen(workId = id, onBack = { navController.popBackStack() })
            }
        }
    }
}

/** Builds the `works?…` route, URL-encoding name/title so a ship's `/` survives. */
private fun worksRoute(field: String, name: String, title: String, sort: String): String =
    "works?field=$field&name=${Uri.encode(name)}&title=${Uri.encode(title)}&sort=$sort"

/** Builds the `author?…` route, URL-encoding the username + display name. */
private fun authorRoute(username: String, name: String): String =
    "author?username=${Uri.encode(username)}&name=${Uri.encode(name)}"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TitledScreen(
    title: String,
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable () -> Unit,
) {
    Scaffold(topBar = { TopAppBar(title = { Text(title) }, actions = actions) }) { padding ->
        androidx.compose.foundation.layout.Box(Modifier.fillMaxSize().padding(padding)) { content() }
    }
}
