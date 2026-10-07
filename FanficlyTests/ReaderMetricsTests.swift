import XCTest
@testable import Fanficly

/// The reading column: phone settings cap line length on wide layouts (a Pro
/// Max in landscape, iPhone Duo unfolded); iPad and Mac keep the plain
/// percentage the user chose.
final class ReaderMetricsTests: XCTestCase {
    func test_narrowPhone_usesThePercentage() {
        let w = ReaderMetrics.textColumnWidth(containerWidth: 402, widthPercent: 90, fontSize: 18, limitLineLength: true)
        XCTAssertEqual(w, 361.8, accuracy: 0.01)
    }

    func test_widePhoneLayout_capsAtAbout80Characters() {
        let w = ReaderMetrics.textColumnWidth(containerWidth: 951, widthPercent: 90, fontSize: 18, limitLineLength: true)
        XCTAssertEqual(w, 18 * ReaderMetrics.maxLineLengthEm)
    }

    func test_capScalesWithTextSize() {
        let big = ReaderMetrics.textColumnWidth(containerWidth: 951, widthPercent: 100, fontSize: 24, limitLineLength: true)
        XCTAssertEqual(big, min(951, 24 * ReaderMetrics.maxLineLengthEm))
    }

    func test_ipadAndMac_keepThePercentage() {
        let w = ReaderMetrics.textColumnWidth(containerWidth: 1366, widthPercent: 70, fontSize: 18, limitLineLength: false)
        XCTAssertEqual(w, 956.2, accuracy: 0.01)
    }
}
