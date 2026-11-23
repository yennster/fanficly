import XCTest
@testable import Fanficly

/// The Undo toast behind one-tap deletes (#169): a scheduled delete hides its
/// rows and only runs when the toast closes, unless Undo drops it.
@MainActor
final class UndoCenterTests: XCTestCase {
    private var commits: [String] = []

    override func setUp() {
        super.setUp()
        commits = []
    }

    private func center(delay: Duration = .seconds(60)) -> UndoCenter {
        UndoCenter(delay: delay)
    }

    func test_schedule_hidesKeysWithoutCommitting() {
        let undo = center()
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)]) { self.commits.append("A") }

        XCTAssertTrue(undo.isPending(UndoCenter.Key.work(1)))
        XCTAssertFalse(undo.isPending(UndoCenter.Key.work(2)))
        XCTAssertEqual(undo.pending?.message, "Deleted “A”")
        XCTAssertEqual(commits, [])
    }

    func test_undo_dropsTheDeleteForGood() {
        let undo = center()
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)]) { self.commits.append("A") }
        undo.undo()

        XCTAssertNil(undo.pending)
        XCTAssertFalse(undo.isPending(UndoCenter.Key.work(1)))
        undo.commitPending()
        XCTAssertEqual(commits, [], "an undone delete never runs")
    }

    func test_commitPending_runsOnce() {
        let undo = center()
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)]) { self.commits.append("A") }
        undo.commitPending()
        undo.commitPending()
        undo.undo()

        XCTAssertEqual(commits, ["A"])
        XCTAssertNil(undo.pending)
    }

    func test_secondDelete_runsTheFirstAndUndoesOnlyItself() {
        let undo = center()
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)]) { self.commits.append("A") }
        undo.schedule("Deleted “B”", keys: [UndoCenter.Key.folder("B")]) { self.commits.append("B") }

        XCTAssertEqual(commits, ["A"])
        XCTAssertFalse(undo.isPending(UndoCenter.Key.work(1)))
        XCTAssertTrue(undo.isPending(UndoCenter.Key.folder("B")))

        undo.undo()
        XCTAssertEqual(commits, ["A"])
    }

    func test_toastClosing_runsTheDelete() async throws {
        let undo = center(delay: .milliseconds(50))
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)]) { self.commits.append("A") }

        for _ in 0..<40 where commits.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(commits, ["A"])
        XCTAssertNil(undo.pending)
    }

    func test_undoneDelete_doesNotRunWhenItsTimeComesUp() async throws {
        let undo = center(delay: .milliseconds(50))
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)]) { self.commits.append("A") }
        undo.undo()

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(commits, [])
    }

    func test_undoManager_undoesTheWaitingDelete() {
        let undo = center()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)], undoManager: manager) { self.commits.append("A") }
        manager.endUndoGrouping()

        XCTAssertTrue(manager.canUndo)
        manager.undo()

        XCTAssertNil(undo.pending)
        XCTAssertEqual(commits, [])
    }

    func test_committedDelete_leavesNothingToUndo() {
        let undo = center()
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)], undoManager: manager) { self.commits.append("A") }
        manager.endUndoGrouping()

        undo.commitPending()
        if manager.canUndo { manager.undo() }  // at most an empty group is left
        XCTAssertEqual(commits, ["A"], "⌘Z can't bring back a delete that already ran")
        XCTAssertNil(undo.pending)
    }

    func test_offer_undoRunsTheRevert() {
        let undo = center()
        undo.offer("Deleted profile “Night”") { self.commits.append("restored") }
        XCTAssertNotNil(undo.pending)
        undo.undo()
        XCTAssertEqual(commits, ["restored"])
        XCTAssertNil(undo.pending)
    }

    func test_offer_closingKeepsTheDelete() {
        let undo = center()
        undo.offer("Deleted profile “Night”") { self.commits.append("restored") }
        undo.commitPending()
        undo.undo()
        XCTAssertEqual(commits, [], "once the toast closes, nothing is put back")
    }

    func test_cancel_dropsTheDeleteWithoutRunningIt() {
        let undo = center()
        undo.schedule("Deleted saved search “X”", keys: [UndoCenter.Key.search("X")]) { self.commits.append("X") }
        undo.cancel(UndoCenter.Key.search("Y"))
        XCTAssertNotNil(undo.pending, "another key leaves it waiting")

        undo.cancel(UndoCenter.Key.search("X"))  // saved again under the same name
        XCTAssertNil(undo.pending)
        undo.commitPending()
        XCTAssertEqual(commits, [])
    }

    func test_toastShowsInTheHostItCameFrom() {
        let undo = center()
        let window = UUID(), otherWindow = UUID(), sheet = UUID()
        undo.addHost(window, parent: nil, undoManager: nil)
        undo.addHost(otherWindow, parent: nil, undoManager: nil)
        undo.addHost(sheet, parent: window, undoManager: nil)

        undo.schedule("Deleted saved filter “F”", keys: [UndoCenter.Key.filter("F")], host: sheet) {}
        XCTAssertTrue(undo.showsToast(in: sheet))
        XCTAssertFalse(undo.showsToast(in: window), "the sheet covers its window's toast")
        XCTAssertFalse(undo.showsToast(in: otherWindow), "never in another window")

        undo.removeHost(sheet)  // the sheet closed with the toast still up
        XCTAssertTrue(undo.showsToast(in: window))
        XCTAssertFalse(undo.showsToast(in: otherWindow))
    }

    func test_hostGivesItsUndoManager() {
        let undo = center()
        let window = UUID()
        let manager = UndoManager()
        manager.groupsByEvent = false
        undo.addHost(window, parent: nil, undoManager: manager)
        manager.beginUndoGrouping()
        undo.schedule("Deleted “A”", keys: [UndoCenter.Key.work(1)], host: window) { self.commits.append("A") }
        manager.endUndoGrouping()

        manager.undo()
        XCTAssertNil(undo.pending)
        XCTAssertEqual(commits, [])
    }
}
