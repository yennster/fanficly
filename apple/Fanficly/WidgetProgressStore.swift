import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct WidgetStoryProgress: Codable, Equatable, Sendable {
    let id: Int
    let title: String
    let author: String
    let progress: Double
    let chapter: Int?
    let paragraph: Int?
    let updatedAt: Date?

    var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var freshnessDate: Date {
        updatedAt ?? .distantPast
    }
}

enum WidgetProgressStore {
    static let appGroupIdentifier = "group.io.github.yennster.fanficly"
    static let lastReadProgressKey = "lastReadProgress"
    static let widgetKind = "FanficlyWidget"

    nonisolated(unsafe) private static var cloudObserver: NSObjectProtocol?
    nonisolated(unsafe) private static var cloudSaveTask: Task<Void, Never>?
    nonisolated(unsafe) private static var widgetReloadTask: Task<Void, Never>?

    static func save(
        id: Int,
        title: String,
        author: String,
        progress: Double,
        chapter: Int? = nil,
        paragraph: Int? = nil,
        updatedAt: Date = .now,
        syncImmediately: Bool = false
    ) {
        let payload = WidgetStoryProgress(
            id: id,
            title: title,
            author: author,
            progress: progress,
            chapter: chapter,
            paragraph: paragraph,
            updatedAt: updatedAt
        )
        save(payload, syncImmediately: syncImmediately)
    }

    static func load() -> WidgetStoryProgress? {
        _ = NSUbiquitousKeyValueStore.default.synchronize()

        let candidates = [
            readLocal(),
            readCloud()
        ].compactMap { $0 }

        guard let newest = candidates.max(by: { $0.freshnessDate < $1.freshnessDate }) else {
            return nil
        }

        writeLocal(newest)
        return newest
    }

    /// This device's marks of entries that must not come back (#209), kept
    /// in the app-group defaults so the widget honours them too. Removing the
    /// iCloud key alone isn't enough: another device may still hold the entry,
    /// or still be reading the work, and save it back.
    static let clearedKey = "lastReadProgress.cleared"
    /// How many dated marks are kept (the newest). They don't expire by age:
    /// a copy this device can't delete (the widget extension's own defaults,
    /// another device's) may sit there for months. Hidden works' marks aren't
    /// capped: there's one per `HiddenWork`.
    static let maxDatedMarks = 200

    /// One mark: a nil `id` covers any work; a nil `at` covers every entry
    /// (the work is hidden), else entries saved no later than it.
    struct ClearedMark: Codable, Equatable, Sendable {
        let id: Int?
        let at: Date?

        func covers(_ progress: WidgetStoryProgress) -> Bool {
            (id == nil || id == progress.id) && (at.map { progress.freshnessDate <= $0 } ?? true)
        }
    }

    /// Test seam: false keeps the store off iCloud key-value storage, so unit
    /// tests never push entries to the developer's other devices.
    nonisolated(unsafe) static var usesCloud = true

    /// Forgets the last-read entry when it names `workId` (nil: whichever work
    /// it names), in the app-group, standard and iCloud copies alike, so the
    /// Continue reading widget stops showing a deleted work's title, or what
    /// was read once the history is cleared (#209). A copy naming another work
    /// stays. It also leaves a mark, so a copy saved before now can't come
    /// back from iCloud. Returns whether anything was removed; the widget is
    /// reloaded then.
    @discardableResult
    static func clear(workId: Int? = nil) -> Bool {
        // Rounded up to a whole second, so the copy cleared now is always covered.
        let now = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 1).rounded(.down))
        var marks = loadMarks().filter { !($0.at != nil && $0.id == workId) }
        marks.append(ClearedMark(id: workId, at: now))
        saveMarks(marks)
        return removeCopies(workId: workId)
    }

    /// A hidden work never shows as the last-read entry on this device,
    /// whenever its copy was saved (another device may still be reading it);
    /// unhiding it lifts that (#209).
    @discardableResult
    static func setHidden(_ workId: Int, hidden: Bool) -> Bool {
        var marks = loadMarks().filter { !($0.id == workId && $0.at == nil) }
        if hidden { marks.append(ClearedMark(id: workId, at: nil)) }
        saveMarks(marks)
        return hidden && removeCopies(workId: workId)
    }

    /// Makes the hidden marks match `hiddenIds`, the library's hidden works:
    /// run at launch, so works hidden before marks existed (or by a restore
    /// that rolled back) are covered, and a mark left for a work no longer
    /// hidden goes (#209).
    @discardableResult
    static func matchHidden(_ hiddenIds: Set<Int>) -> Bool {
        var marks = loadMarks()
        let marked = Set(marks.compactMap { mark in mark.at == nil ? mark.id : nil })
        guard marked != hiddenIds else { return false }
        marks.removeAll { mark in mark.at == nil }
        marks.append(contentsOf: hiddenIds.map { ClearedMark(id: $0, at: nil) })
        saveMarks(marks)
        var removed = false
        for id in hiddenIds.subtracting(marked) where removeCopies(workId: id) { removed = true }
        return removed
    }

    private static func removeCopies(workId: Int?) -> Bool {
        func names(_ payload: WidgetStoryProgress?) -> Bool {
            guard let payload else { return false }
            return workId == nil || payload.id == workId
        }

        var removed = false
        let shared = UserDefaults(suiteName: appGroupIdentifier)
        if names(decode(shared?.data(forKey: lastReadProgressKey))) {
            shared?.removeObject(forKey: lastReadProgressKey)
            removed = true
        }
        if names(decode(UserDefaults.standard.data(forKey: lastReadProgressKey))) {
            UserDefaults.standard.removeObject(forKey: lastReadProgressKey)
            removed = true
        }
        // A pending mirror is the latest save, which a local copy above held:
        // drop it so it can't write the entry back to iCloud.
        if removed { cloudSaveTask?.cancel() }
        if usesCloud, names(decode(NSUbiquitousKeyValueStore.default.data(forKey: lastReadProgressKey))) {
            NSUbiquitousKeyValueStore.default.removeObject(forKey: lastReadProgressKey)
            NSUbiquitousKeyValueStore.default.synchronize()
            removed = true
        }
        if removed { reloadWidgetsNow() }
        return removed
    }

    private static var markDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func loadMarks() -> [ClearedMark] {
        guard let data = markDefaults.data(forKey: clearedKey),
              let marks = try? JSONDecoder().decode([ClearedMark].self, from: data) else { return [] }
        return marks
    }

    private static func saveMarks(_ marks: [ClearedMark]) {
        // Every hidden work's mark, then the newest dated ones (on a tie,
        // the one added last).
        var seenHidden = Set<Int?>()
        let hidden = marks.filter { mark in mark.at == nil && seenHidden.insert(mark.id).inserted }
        let dated = marks.enumerated()
            .filter { pair in pair.element.at != nil }
            .sorted { lhs, rhs in
                lhs.element.at! != rhs.element.at! ? lhs.element.at! > rhs.element.at! : lhs.offset > rhs.offset
            }
            .prefix(maxDatedMarks)
            .map(\.element)
        let kept = hidden + dated
        if kept.isEmpty {
            markDefaults.removeObject(forKey: clearedKey)
        } else if let data = try? JSONEncoder().encode(kept) {
            markDefaults.set(data, forKey: clearedKey)
        }
    }

    /// The copy, unless a mark covers it.
    private static func allowed(_ progress: WidgetStoryProgress?, _ marks: [ClearedMark]) -> WidgetStoryProgress? {
        guard let progress, !marks.contains(where: { $0.covers(progress) }) else { return nil }
        return progress
    }

    static func installCloudSyncObserver() {
        guard cloudObserver == nil else { return }

        _ = NSUbiquitousKeyValueStore.default.synchronize()
        syncCloudToLocal()
        reloadWidgets()
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            syncCloudToLocal()
        }
    }

    static func syncCloudToLocal() {
        guard let cloudProgress = readCloud() else { return }
        if let localProgress = readLocal(),
           localProgress.freshnessDate > cloudProgress.freshnessDate {
            return
        }

        writeLocal(cloudProgress)
        reloadWidgets()
    }

    private static func save(_ payload: WidgetStoryProgress, syncImmediately: Bool) {
        writeLocal(payload)
        scheduleWidgetReload()
        writeCloud(payload, syncImmediately: syncImmediately)
    }

    private static func writeCloud(_ payload: WidgetStoryProgress, syncImmediately: Bool) {
        cloudSaveTask?.cancel()
        guard usesCloud else { return }

        if syncImmediately {
            writeCloudNow(payload)
            reloadWidgetsNow()
            return
        }

        cloudSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            writeCloudNow(payload)
            await MainActor.run {
                reloadWidgetsNow()
            }
        }
    }

    private static func scheduleWidgetReload() {
        widgetReloadTask?.cancel()
        widgetReloadTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                reloadWidgetsNow()
            }
        }
    }

    private static func writeCloudNow(_ payload: WidgetStoryProgress) {
        guard usesCloud, let data = encode(payload) else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: lastReadProgressKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    // Reads skip any copy a cleared mark covers (#209).
    private static func readLocal() -> WidgetStoryProgress? {
        let sharedData = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: lastReadProgressKey)
        let standardData = UserDefaults.standard.data(forKey: lastReadProgressKey)
        let marks = loadMarks()

        return [allowed(decode(sharedData), marks), allowed(decode(standardData), marks)]
            .compactMap { $0 }
            .max(by: { $0.freshnessDate < $1.freshnessDate })
    }

    private static func readCloud() -> WidgetStoryProgress? {
        guard usesCloud else { return nil }
        return allowed(decode(NSUbiquitousKeyValueStore.default.data(forKey: lastReadProgressKey)), loadMarks())
    }

    private static func writeLocal(_ payload: WidgetStoryProgress) {
        guard let data = encode(payload) else { return }
        UserDefaults(suiteName: appGroupIdentifier)?.set(data, forKey: lastReadProgressKey)
        UserDefaults.standard.set(data, forKey: lastReadProgressKey)
    }

    private static func encode(_ payload: WidgetStoryProgress) -> Data? {
        try? JSONEncoder().encode(payload)
    }

    private static func decode(_ data: Data?) -> WidgetStoryProgress? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(WidgetStoryProgress.self, from: data)
    }

    private static func reloadWidgets() {
        scheduleWidgetReload()
    }

    private static func reloadWidgetsNow() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }
}
