import XCTest
@testable import MinutesCore

final class ActivityCopyTests: XCTestCase {
    func testProcessFinishedLine() {
        let line = ActivityCopy.line(for: .processFinished(name: "xcodebuild", ranForSeconds: 180))
        XCTAssertTrue(line.lowercased().contains("xcodebuild") || line.lowercased().contains("finished") || line.lowercased().contains("job"))
    }

    func testAppSwitchHasName() {
        let line = ActivityCopy.line(for: .appActivated(name: "Safari", bundleID: "com.apple.Safari"))
        XCTAssertFalse(line.isEmpty)
    }

    func testEventSummary() {
        XCTAssertTrue(ActivityEvent.screenDidWake.summary.lowercased().contains("wake")
            || ActivityEvent.screenDidWake.summary.lowercased().contains("awake")
            || ActivityEvent.screenDidWake.summary.lowercased().contains("display"))
    }
}
