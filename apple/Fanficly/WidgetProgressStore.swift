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
        guard let data = encode(payload) else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: lastReadProgressKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private static func readLocal() -> WidgetStoryProgress? {
        let sharedData = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: lastReadProgressKey)
        let standardData = UserDefaults.standard.data(forKey: lastReadProgressKey)

        return [decode(sharedData), decode(standardData)]
            .compactMap { $0 }
            .max(by: { $0.freshnessDate < $1.freshnessDate })
    }

    private static func readCloud() -> WidgetStoryProgress? {
        decode(NSUbiquitousKeyValueStore.default.data(forKey: lastReadProgressKey))
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
