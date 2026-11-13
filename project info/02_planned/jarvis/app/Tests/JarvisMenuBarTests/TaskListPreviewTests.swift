import XCTest
import SwiftUI
import JarvisDomain
@testable import JarvisMenuBar

@MainActor final class TaskListPreviewTests: XCTestCase {
    func testMenuSnapshotsWithExplicitTestData() throws {
        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:1")!, session: URLSession(configuration: .ephemeral))
        let running = JarvisTask(title: "【测试数据】进行中任务", status: .running)
        let completed = JarvisTask(title: "【测试数据】已完成任务", status: .completed)
        for (name, tasks, expanded, height) in [
            ("empty", [JarvisTask](), false, 520.0),
            ("running", [running, completed], false, 520.0),
            ("history", [running, completed], true, 380.0)
        ] {
            let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-menu-test-\(name)-\(UUID().uuidString).png")
            let view = TaskListView(client: client, previewTasks: tasks, previewHistoryExpanded: expanded, previewMoreExpanded: name == "history").disabled(true)
            try VisualPreviewHarness.render(view, width: 320, height: height, to: output)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            print("JARVIS_MENU_TEST_IMAGE: \(output.path)")
        }
    }
}
