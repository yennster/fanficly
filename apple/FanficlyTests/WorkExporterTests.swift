import XCTest
@testable import Fanficly

/// `WorkExporter` drives the export → share-sheet flow (the state lives on the
/// presenting screen so the sheet survives the picker menu dismissing — the
/// VoiceOver bug). Verify success publishes a share item and failure surfaces
/// the alert message instead of dying silently.
@MainActor
final class WorkExporterTests: XCTestCase {
    func testSuccessfulExportPublishesShareItem() async {
        let exporter = WorkExporter()
        await exporter.export(workId: 1, title: "My Fic", format: .epub, client: StubAO3Client())

        XCTAssertEqual(exporter.shareItem?.url.lastPathComponent, "My Fic.epub")
        XCTAssertNil(exporter.errorMessage)
        XCTAssertFalse(exporter.isExporting)
    }

    func testFailedExportSurfacesErrorAlert() async {
        let client = StubAO3Client()
        client.exportError = AO3Error.http(status: 503)
        let exporter = WorkExporter()
        await exporter.export(workId: 1, title: "My Fic", format: .pdf, client: client)

        XCTAssertNil(exporter.shareItem)
        XCTAssertEqual(exporter.errorMessage?.contains("PDF"), true)
        XCTAssertFalse(exporter.isExporting)
    }
}

/// `KudosGiver` sends one kudo per tap, remembers it per account on this
/// device so the menu item reads "Kudos Left", and turns AO3's refusals into
/// the alert. Each test gets its own defaults suite so nothing leaks.
@MainActor
final class KudosGiverTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: "test.kudos.\(UUID().uuidString)")!

    func testLeavingKudosRemembersTheWorkForThatAccount() async {
        let client = StubAO3Client()
        let giver = KudosGiver(defaults: defaults)
        await giver.leave(workId: 7, username: "reader", client: client)

        XCTAssertEqual(client.kudosCalls, [7])
        XCTAssertTrue(giver.hasLeft)
        XCTAssertEqual(giver.result?.title, "Kudos left")
        XCTAssertTrue(KudosStore.hasLeft(workId: 7, username: "Reader", defaults: defaults))
        XCTAssertFalse(KudosStore.hasLeft(workId: 7, username: "someone-else", defaults: defaults))
        XCTAssertFalse(KudosStore.hasLeft(workId: 8, username: "reader", defaults: defaults))
    }

    func testASecondTapSendsNothing() async {
        let client = StubAO3Client()
        let giver = KudosGiver(defaults: defaults)
        await giver.leave(workId: 7, username: "reader", client: client)
        await giver.leave(workId: 7, username: "reader", client: client)

        XCTAssertEqual(client.kudosCalls, [7])
    }

    func testRememberedKudosShowOnTheNextScreen() {
        KudosStore.markLeft(workId: 7, username: "reader", defaults: defaults)
        let giver = KudosGiver(defaults: defaults)
        giver.refresh(workId: 7, username: "reader")
        XCTAssertTrue(giver.hasLeft)
        giver.refresh(workId: 7, username: nil)
        XCTAssertFalse(giver.hasLeft)
    }

    func testLoggedOutSendsNothing() async {
        let client = StubAO3Client()
        let giver = KudosGiver(defaults: defaults)
        await giver.leave(workId: 7, username: nil, client: client)

        XCTAssertTrue(client.kudosCalls.isEmpty)
        XCTAssertFalse(giver.hasLeft)
    }

    func testAlreadyLeftOnAO3IsRemembered() async {
        let client = StubAO3Client()
        client.kudosResult = .success(.alreadyLeft)
        let giver = KudosGiver(defaults: defaults)
        await giver.leave(workId: 7, username: "reader", client: client)

        XCTAssertTrue(giver.hasLeft)
        XCTAssertEqual(giver.result?.title, "Kudos already left")
        XCTAssertTrue(KudosStore.hasLeft(workId: 7, username: "reader", defaults: defaults))
    }

    func testRefusalShowsAO3sReasonAndRemembersNothing() async {
        let client = StubAO3Client()
        client.kudosResult = .failure(AO3Error.kudosRejected(message: "You can't leave kudos on your own work."))
        let giver = KudosGiver(defaults: defaults)
        await giver.leave(workId: 7, username: "reader", client: client)

        XCTAssertFalse(giver.hasLeft)
        XCTAssertEqual(giver.result?.message, "You can't leave kudos on your own work.")
        XCTAssertFalse(KudosStore.hasLeft(workId: 7, username: "reader", defaults: defaults))
        XCTAssertFalse(giver.isSending)
    }

    func testExpiredLoginAsksToLogInAgain() async {
        let client = StubAO3Client()
        client.kudosResult = .failure(AO3Error.unauthorized)
        let giver = KudosGiver(defaults: defaults)
        await giver.leave(workId: 7, username: "reader", client: client)

        XCTAssertFalse(giver.hasLeft)
        XCTAssertEqual(giver.result?.message.contains("Log in again"), true)
    }
}
