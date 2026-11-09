import XCTest
@testable import JarvisMenuBar

final class TaskListVisibilityTests: XCTestCase {
    func testHistoryStartsCollapsedAndCanToggle() {
        var state = TaskHistoryVisibility()
        XCTAssertFalse(state.isExpanded)
        state.toggle()
        XCTAssertTrue(state.isExpanded)
        state.toggle()
        XCTAssertFalse(state.isExpanded)
    }
}
