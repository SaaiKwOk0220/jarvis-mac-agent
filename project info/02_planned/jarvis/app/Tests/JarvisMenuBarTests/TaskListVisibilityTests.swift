import XCTest
import JarvisDomain
@testable import JarvisMenuBar

final class TaskListVisibilityTests: XCTestCase {
    func testErrorKeepsPendingTaskVisibleWithStaleWarning() {
        let task = JarvisTask(title: "测试审批", status: .awaitingApproval)
        let state = TaskListPresentation(tasks: [task], history: TaskHistoryVisibility(), hasError: true)
        XCTAssertEqual(state.visibleTasks.map(\.id), [task.id])
        XCTAssertTrue(state.showsStaleWarning)
        XCTAssertFalse(TaskListPresentation(tasks: [], history: TaskHistoryVisibility(), hasError: true).showsStaleWarning)
    }
    func testVoiceStatusPrioritizesRecording() {
        XCTAssertEqual(VoiceInterfaceStatus.label(recording: true, running: true, speaking: true), "聆听中")
        XCTAssertEqual(VoiceInterfaceStatus.label(recording: false, running: true, speaking: false), "任务进行中")
        XCTAssertEqual(VoiceInterfaceStatus.label(recording: false, running: false, speaking: true), "朗读中")
        XCTAssertEqual(VoiceInterfaceStatus.label(recording: false, running: false, speaking: false), "待命")
    }

    func testCollapsedHistoryKeepsUnfinishedTasksVisible() {
        let state = TaskHistoryVisibility()
        for status in [TaskStatus.draft, .planning, .running, .awaitingApproval, .blocked] {
            XCTAssertTrue(state.shows(status), "\(status)")
        }
        for status in [TaskStatus.completed, .cancelled, .failed] {
            XCTAssertFalse(state.shows(status), "\(status)")
        }
    }

    func testHistoryStartsCollapsedAndCanToggle() {
        var state = TaskHistoryVisibility()
        XCTAssertFalse(state.isExpanded)
        state.toggle()
        XCTAssertTrue(state.isExpanded)
        state.toggle()
        XCTAssertFalse(state.isExpanded)
    }
}
