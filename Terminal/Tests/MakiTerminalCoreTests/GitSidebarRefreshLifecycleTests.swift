import XCTest
@testable import MakiTerminalCore

final class GitSidebarRefreshLifecycleTests: XCTestCase {
    func testVisibilityAndEnablementInvalidateOlderRequests() {
        var lifecycle = GitSidebarRefreshLifecycle()
        lifecycle.setEnabled(true)
        lifecycle.setWindowVisible(true)
        let visibleRequest = lifecycle.beginRequest()
        XCTAssertTrue(lifecycle.canPublish(visibleRequest))

        lifecycle.setWindowVisible(false)
        XCTAssertFalse(lifecycle.canPublish(visibleRequest))
        XCTAssertFalse(lifecycle.shouldRefresh)

        lifecycle.setWindowVisible(true)
        let reopenedRequest = lifecycle.beginRequest()
        XCTAssertTrue(lifecycle.canPublish(reopenedRequest))
        XCTAssertFalse(lifecycle.canPublish(visibleRequest))

        lifecycle.setEnabled(false)
        XCTAssertFalse(lifecycle.canPublish(reopenedRequest))
        XCTAssertFalse(lifecycle.shouldRefresh)
    }
}
