import SwiftUI

// What's New (#422): a sheet the first time the app opens after an update,
// and Settings → About → What's New with every release. The text comes from
// the repository's shared changelog/whats-new.json (the Windows app reads the
// same file), bundled into the app, so nothing is fetched. The release
// workflow's store notes come from the same entry (bin/release-notes.py).

/// One release in changelog/whats-new.json, with only this app's themes.
struct WhatsNewRelease: Codable, Hashable, Identifiable, Sendable {
    struct Theme: Codable, Hashable, Sendable {
        /// An SF Symbol name (the Windows app maps the same names).
        let icon: String
        let title: String
        let detail: String
        /// "apple", "windows"; nil means the release's platforms.
        var platforms: [String]? = nil
    }

    let version: String
    /// yyyy-MM-dd; nil until the release goes out.
    var date: String? = nil
    /// The platforms of every theme that names none; nil means all.
    var platforms: [String]? = nil
    var themes: [Theme]

    var id: String { version }

    /// "1.14" for "1.14.0"; "1.11.1" as it is.
    var displayVersion: String {
        let parts = version.split(separator: ".")
        return parts.count == 3 && parts[2] == "0" ? parts[0...1].joined(separator: ".") : version
    }

    /// The release date in the reader's own style, or nil.
    var displayDate: String? {
        guard let date,
              let day = try? Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().parse(date) else { return nil }
        // The changelog's day, wherever the reader is.
        return day.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }
}

enum WhatsNew {
    /// This app's name in the changelog's `platforms` lists.
    static let platform = "apple"
    /// The newest release whose What's New this device has shown (or skipped
    /// on a fresh install). The Windows app uses the same key.
    static let lastSeenKey = "whatsNew.lastSeenVersion"

    private struct File: Decodable {
        let releases: [WhatsNewRelease]
    }

    /// The changelog's releases for `platform`, newest first: each keeps only
    /// the themes for that platform, and a release left with none is dropped.
    static func releases(from data: Data, platform: String = platform) throws -> [WhatsNewRelease] {
        try JSONDecoder().decode(File.self, from: data).releases.compactMap { release in
            var release = release
            release.themes = release.themes.filter { ($0.platforms ?? release.platforms ?? [platform]).contains(platform) }
            return release.themes.isEmpty ? nil : release
        }
    }

    /// The bundled changelog (empty in the App Clip, which doesn't carry it).
    static let releases: [WhatsNewRelease] = {
        guard let url = Bundle.main.url(forResource: "whats-new", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? releases(from: data)) ?? []
    }()

    enum LaunchDecision: Equatable {
        /// Nothing to do this launch.
        case nothing
        /// A fresh install: note the newest release as seen, show nothing.
        case record(String)
        /// Show this release's What's New (and note it as seen).
        case show(WhatsNewRelease)
    }

    /// What a launch does. `isExistingUser`: the app was set up before this
    /// launch (the 17+ confirmation was already given), so this is an update,
    /// not a fresh install. `openedIntoContent`: the launch opened a story or
    /// a link (a widget, notification, shared link or file), which the sheet
    /// mustn't cover; it waits for the next plain launch.
    static func launchDecision(newest: WhatsNewRelease?, lastSeen: String?, isExistingUser: Bool,
                               openedIntoContent: Bool) -> LaunchDecision {
        guard let newest, lastSeen != newest.version else { return .nothing }
        guard isExistingUser else { return .record(newest.version) }
        return openedIntoContent ? .nothing : .show(newest)
    }
}

/// Once per process: several windows (iPad, the Mac) each have a RootView.
@MainActor
enum WhatsNewLaunch {
    static var checked = false
}

/// One theme: its icon, title and line.
private struct WhatsNewThemeRow: View {
    let theme: WhatsNewRelease.Theme
    var large = false

    var body: some View {
        HStack(alignment: .top, spacing: large ? 16 : 12) {
            Image(systemName: theme.icon)
                .font(large ? .title2 : .body)
                .foregroundStyle(.tint)
                .frame(width: large ? 36 : 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.title)
                    .font(.headline)
                Text(theme.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The sheet the first launch after an update shows.
struct WhatsNewSheet: View {
    let release: WhatsNewRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("What's New in Fanficly \(release.displayVersion)")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 24)
                    ForEach(release.themes, id: \.self) { theme in
                        WhatsNewThemeRow(theme: theme, large: true)
                    }
                    NavigationLink {
                        WhatsNewHistoryView()
                    } label: {
                        Text("See All Updates")
                    }
                    .accessibilityIdentifier("whatsNew.history")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: 520)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("whatsNew.continue")
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // A Mac sheet sizes to its content; give it room for the themes.
        .frame(minWidth: UIDevice.current.userInterfaceIdiom == .mac ? 460 : nil,
               minHeight: UIDevice.current.userInterfaceIdiom == .mac ? 560 : nil)
    }
}

/// Settings → About → What's New: every release, newest first.
struct WhatsNewHistoryView: View {
    var releases: [WhatsNewRelease] = WhatsNew.releases

    var body: some View {
        List {
            ForEach(releases) { release in
                Section {
                    ForEach(release.themes, id: \.self) { theme in
                        WhatsNewThemeRow(theme: theme)
                            .padding(.vertical, 2)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Version \(release.displayVersion)")
                        Spacer()
                        if let date = release.displayDate {
                            Text(date)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .overlay {
            if releases.isEmpty {
                ContentUnavailableView("No Updates Listed", systemImage: "sparkles")
            }
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
    }
}
