import Foundation

/// A shareable link to an AO3 work on fanficly.app, the App Clip's invocation
/// URL (#292): `https://fanficly.app/works/<id>`, optionally with
/// `?chapter=<n>` (the 1-based chapter position, as `fanficly://resume`
/// uses). With the full app installed the same link opens it as a universal
/// link; without it, iOS offers the App Clip; anywhere else the website's
/// `/works/` page links to the work on AO3.
///
/// Compiled into the app and the App Clip. The website's
/// `apple-app-site-association` and the clip's associated domain name the
/// same host (`bin/app-clip.py aasa --check` keeps them in step).
struct WorkLink: Equatable, Sendable {
    static let host = "fanficly.app"

    let workId: Int
    /// 1-based chapter position, when the link names one.
    let chapter: Int?

    init(workId: Int, chapter: Int? = nil) {
        self.workId = workId
        self.chapter = chapter
    }

    /// The link for a work, as it would be shared.
    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/works/\(workId)"
        if let chapter {
            components.queryItems = [URLQueryItem(name: "chapter", value: String(chapter))]
        }
        return components.url!
    }

    /// Where the reader should open: the chapter's first paragraph, or nil
    /// for the saved place (or the start).
    var anchor: ReadingAnchor? {
        chapter.map { ReadingAnchor(chapter: $0, paragraph: 0) }
    }

    /// Parses a fanficly.app work link. Anything else (another host, another
    /// path, a work id that isn't a positive number) is nil: only links of
    /// this exact shape open a work.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              host == Self.host || host == "www.\(Self.host)" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 || (parts.count == 3 && parts[2].isEmpty),
              parts[0].lowercased() == "works",
              let id = Int(parts[1]), id > 0 else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let chapter = query?.first(where: { $0.name == "chapter" })?.value
            .flatMap { Int($0) }
            .flatMap { $0 > 0 ? $0 : nil }
        self.init(workId: id, chapter: chapter)
    }
}

/// The work a reader opened in the App Clip, kept in the app group for the
/// full app (#292). The clip and the app share the app group container, and
/// installing the app keeps it, so the app's first launch can open the same
/// work. The reading place itself travels the way it always does: the
/// reader's saves write it to `WidgetProgressStore` (also in the app group),
/// and `RootView`'s resume route reads it from there.
enum ClipHandoff {
    static let workIdKey = "appClip.handoff.workId"
    static let dateKey = "appClip.handoff.date"
    /// An older handoff is dropped: the reader has moved on.
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: WidgetProgressStore.appGroupIdentifier)
    }

    /// Called by the clip each time it opens a work.
    static func record(workId: Int, now: Date = .now, defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(workId, forKey: workIdKey)
        defaults?.set(now.timeIntervalSince1970, forKey: dateKey)
    }

    /// The work to open, once: reading it clears it, so only the app's first
    /// launch after the clip (or the first after the clip opened another
    /// work) acts on it.
    static func take(now: Date = .now, defaults: UserDefaults? = sharedDefaults) -> Int? {
        guard let defaults else { return nil }
        let workId = defaults.integer(forKey: workIdKey)
        let stamp = defaults.double(forKey: dateKey)
        defaults.removeObject(forKey: workIdKey)
        defaults.removeObject(forKey: dateKey)
        guard workId > 0, stamp > 0 else { return nil }
        let age = now.timeIntervalSince1970 - stamp
        guard age >= 0, age <= maximumAge else { return nil }
        return workId
    }
}
