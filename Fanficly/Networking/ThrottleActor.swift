import Foundation

actor ThrottleActor {
    private let minimumInterval: TimeInterval
    private var nextEarliest: Date = .distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func wait() async {
        let now = Date()
        if now < nextEarliest {
            let delay = nextEarliest.timeIntervalSince(now)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        nextEarliest = Date().addingTimeInterval(minimumInterval)
    }
}
