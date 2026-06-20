package io.github.yennster.fanficly

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import io.github.yennster.fanficly.net.parse.SearchResultsParser
import io.github.yennster.fanficly.ui.library.LibraryScreen
import io.github.yennster.fanficly.ui.search.SearchScreen
import io.github.yennster.fanficly.ui.settings.SettingsScreen
import io.github.yennster.fanficly.ui.theme.FanficlyTheme
import io.github.yennster.fanficly.ui.work.WorkScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val deepLinkWorkId = workIdFromIntent(intent)
        setContent {
            FanficlyTheme {
                FanficlyApp(initialWorkId = deepLinkWorkId)
            }
        }
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
    LIBRARY("library", "Library", Icons.Filled.Book),
    SETTINGS("settings", "Settings", Icons.Filled.Settings),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FanficlyApp(initialWorkId: Int?) {
    val navController = rememberNavController()
    val backStack by navController.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    val onWorkRoute = currentRoute?.startsWith("work/") == true

    Scaffold(
        bottomBar = {
            if (!onWorkRoute) {
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
            composable(Tab.LIBRARY.route) {
                TitledScreen("Library") { LibraryScreen(onOpenWork = { navController.navigate("work/$it") }) }
            }
            composable(Tab.SETTINGS.route) {
                TitledScreen("Settings") { SettingsScreen() }
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
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TitledScreen(title: String, content: @Composable () -> Unit) {
    Scaffold(topBar = { TopAppBar(title = { Text(title) }) }) { padding ->
        androidx.compose.foundation.layout.Box(Modifier.fillMaxSize().padding(padding)) { content() }
    }
}
