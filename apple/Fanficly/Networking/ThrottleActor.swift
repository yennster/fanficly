import Foundation

actor ThrottleActor {
    private let minimumInterval: TimeInterval
    private var nextEarliest: Date = .distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func wait() async {
        // Reserve this caller's slot *before* suspending. Actor methods run
        // synchronously up to the first `await`, so reading and bumping
        // `nextEarliest` here is atomic per call: concurrent callers each grab a
        // distinct, strictly-spaced instant instead of all reading the same
        // value, sleeping to the same time, and firing together. The old code
        // set `nextEarliest` only after the sleep, so a burst of concurrent
        // requests leaked through at once — overrunning AO3's rate limit, which
        // makes AO3 stall/tarpit the client until requests time out.
        let now = Date()
        let scheduled = max(now, nextEarliest)
        nextEarliest = scheduled.addingTimeInterval(minimumInterval)

        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
