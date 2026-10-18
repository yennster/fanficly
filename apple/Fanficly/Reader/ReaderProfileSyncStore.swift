import Foundation

enum ReaderProfileSyncStore {
    private static let profilesKey = "reader.profiles"
    private static let profilesUpdatedAtKey = "reader.profiles.updatedAt"

    nonisolated(unsafe) private static var cloudObserver: NSObjectProtocol?

    static func installCloudSyncObserver() {
        guard cloudObserver == nil else { return }

        _ = NSUbiquitousKeyValueStore.default.synchronize()
        syncCloudToLocal()
        publishLocalProfilesIfCloudIsEmpty()

        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            syncCloudToLocal()
        }
    }

    static func publishLocalProfiles(_ profilesJSON: String) {
        guard !profilesJSON.isEmpty else { return }

        let cloudJSON = NSUbiquitousKeyValueStore.default.string(forKey: profilesKey)
        let mergedJSON = ReaderProfile.mergedProfiles(localJSON: cloudJSON, incomingJSON: profilesJSON)

        if UserDefaults.standard.string(forKey: profilesKey) != mergedJSON {
            UserDefaults.standard.set(mergedJSON, forKey: profilesKey)
        }

        NSUbiquitousKeyValueStore.default.set(mergedJSON, forKey: profilesKey)
        NSUbiquitousKeyValueStore.default.set(Date.now.timeIntervalSince1970, forKey: profilesUpdatedAtKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    static func syncCloudToLocal() {
        guard let cloudJSON = NSUbiquitousKeyValueStore.default.string(forKey: profilesKey),
              !cloudJSON.isEmpty else {
            return
        }

        let defaults = UserDefaults.standard
        let localJSON = defaults.string(forKey: profilesKey)
        let mergedJSON = ReaderProfile.mergedProfiles(localJSON: localJSON, incomingJSON: cloudJSON)

        if localJSON != mergedJSON {
            defaults.set(mergedJSON, forKey: profilesKey)
        }

        if cloudJSON != mergedJSON {
            NSUbiquitousKeyValueStore.default.set(mergedJSON, forKey: profilesKey)
            NSUbiquitousKeyValueStore.default.set(Date.now.timeIntervalSince1970, forKey: profilesUpdatedAtKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    private static func publishLocalProfilesIfCloudIsEmpty() {
        let cloudJSON = NSUbiquitousKeyValueStore.default.string(forKey: profilesKey)
        guard cloudJSON?.isEmpty ?? true,
              let localJSON = UserDefaults.standard.string(forKey: profilesKey),
              !localJSON.isEmpty else {
            return
        }

        publishLocalProfiles(localJSON)
    }
}
