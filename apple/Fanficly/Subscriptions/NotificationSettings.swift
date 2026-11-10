import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Whether this app's notifications can show, as Settings → Notifications
/// says it (#192). The Windows app's Notifications row is the model.
enum NotificationsStatus: Equatable, Sendable {
    /// Allowed (including provisional and App Clip-style ephemeral grants).
    case on
    /// The reader turned them off, or tapped Don't Allow.
    case off
    /// The system hasn't asked yet: the first follow asks.
    case notAsked

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .on
        case .notDetermined: self = .notAsked
        case .denied: self = .off
        @unknown default: self = .off
        }
    }

    static func current() async -> NotificationsStatus {
        NotificationsStatus(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }
}

/// The one-time "notifications are off" prompt after a follow (#192), like
/// the Windows app's: iOS shows its own permission alert only once, so a
/// reader who tapped Don't Allow is told, once, why no alerts arrive and
/// offered the system's notification settings. Shown by
/// `notificationsOffPrompt()` on `RootView`.
@MainActor
@Observable
final class NotificationsOffPrompt {
    static let shared = NotificationsOffPrompt()

    /// Set once the prompt has been shown; the Windows app's key.
    nonisolated static let shownKey = "notifications.permissionPromptShown"

    var isShowing = false

    /// Only when notifications were already off before this follow asked:
    /// right after the reader answers the system's own alert, a second
    /// alert would only nag. Never twice.
    nonisolated static func shouldPrompt(statusBeforeAsking: UNAuthorizationStatus, alreadyShown: Bool) -> Bool {
        statusBeforeAsking == .denied && !alreadyShown
    }

    /// Called by `NotificationsAuthorization.request()` with the status it
    /// found before asking.
    func noteRequest(statusBeforeAsking: UNAuthorizationStatus) {
        let defaults = UserDefaults.standard
        guard !FanficlyApp.isDemoMode, !FanficlyApp.isTestMode else { return }
        guard Self.shouldPrompt(statusBeforeAsking: statusBeforeAsking,
                                alreadyShown: defaults.bool(forKey: Self.shownKey)) else { return }
        defaults.set(true, forKey: Self.shownKey)
        isShowing = true
    }
}

enum NotificationSystemSettings {
    /// This app's page in the system's notification settings. The Mac's
    /// System Settings has no per-app link Catalyst can open, so there it
    /// opens the Notifications pane.
    @MainActor
    static func open() {
        #if canImport(UIKit)
        #if targetEnvironment(macCatalyst)
        let fallback = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #else
        let fallback = URL(string: UIApplication.openSettingsURLString)
        #endif
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url) { opened in
            guard !opened, let fallback else { return }
            Task { @MainActor in UIApplication.shared.open(fallback) }
        }
        #endif
    }
}

/// Settings → Notifications: whether alerts can show, and the way to change
/// that (#192).
struct NotificationsSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    /// Nil until the first read, so the row doesn't flash a wrong status.
    @State private var status: NotificationsStatus?

    var body: some View {
        Section {
            LabeledContent("Notifications") {
                Text(statusText)
            }
            .accessibilityIdentifier("settings.notifications.status")
            if status == .notAsked {
                Button("Turn On Notifications") {
                    Task {
                        _ = await NotificationsAuthorization.request()
                        status = await NotificationsStatus.current()
                    }
                }
                .accessibilityIdentifier("settings.notifications.turnOn")
            } else {
                Button("Open Notification Settings") {
                    NotificationSystemSettings.open()
                }
                .accessibilityIdentifier("settings.notifications.open")
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(footerText)
        }
        // Again on coming back from the system's settings.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            status = await NotificationsStatus.current()
        }
    }

    private var statusText: LocalizedStringKey {
        switch status {
        case .on: "On"
        case .off: "Off"
        case .notAsked: "Not Set Up"
        case nil: ""
        }
    }

    private var footerText: LocalizedStringKey {
        switch status {
        case .off:
            "Notifications for Fanficly are off, so you won't hear about new chapters and new works. Turn them on in Settings."
        default:
            "Fanficly checks the works and authors you follow, your saved search alerts and your AO3 subscriptions in the background, and posts a notification when something new appears. Tap a notification to open what it's about."
        }
    }
}

extension View {
    /// The one-time "notifications are off" prompt (`NotificationsOffPrompt`).
    func notificationsOffPrompt() -> some View {
        modifier(NotificationsOffPromptModifier())
    }
}

private struct NotificationsOffPromptModifier: ViewModifier {
    @State private var prompt = NotificationsOffPrompt.shared

    func body(content: Content) -> some View {
        content.alert("Turn On Notifications?", isPresented: $prompt.isShowing) {
            Button("Open Settings") { NotificationSystemSettings.open() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Fanficly lets you know when stories and authors you follow post something new, but notifications for Fanficly are off.")
        }
    }
}
