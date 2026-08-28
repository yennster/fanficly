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
