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

    /// Every release in the bundled changelog for this app, unreleased ones
    /// too (empty in the App Clip, which doesn't carry it).
    static let allReleases: [WhatsNewRelease] = {
        guard let url = Bundle.main.url(forResource: "whats-new", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? releases(from: data)) ?? []
    }()

    /// The releases the app shows: the pop-up's newest and Settings' list.
    static let releases: [WhatsNewRelease] = released(allReleases, appVersion: Bundle.main.shortVersionString)

    /// Only shipped releases: an entry gets its `date` when its release goes
    /// out, and one newer than this build (a beta, a hotfix built after the
    /// next version's entry was written) describes features it doesn't have.
    static func released(_ releases: [WhatsNewRelease], appVersion: String) -> [WhatsNewRelease] {
        releases.filter { release in
            release.date != nil && release.version.compare(appVersion, options: .numeric) != .orderedDescending
        }
    }

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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: theme.icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28)
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

/// The small box the first launch after an update shows, centered over a
/// dimmed app: the release's headlines (one line each), Continue, and See All
/// Updates, which opens the history with every detail.
struct WhatsNewCard: View {
    let release: WhatsNewRelease
    let onContinue: () -> Void
    let onSeeAll: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                Text("What's New in Fanficly \(release.displayVersion)")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(release.themes, id: \.self) { theme in
                        Label {
                            Text(theme.title)
                                .font(.subheadline)
                        } icon: {
                            Image(systemName: theme.icon)
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                        }
                    }
                }
                VStack(spacing: 6) {
                    Button(action: onContinue) {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("whatsNew.continue")
                    Button(action: onSeeAll) {
                        Text("See All Updates")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("whatsNew.history")
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 6)
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity)
    }
}

/// See All Updates from the box: the history in a sheet of its own.
struct WhatsNewHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WhatsNewHistoryView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
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
