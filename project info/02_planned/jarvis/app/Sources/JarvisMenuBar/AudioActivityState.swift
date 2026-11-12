import Foundation
import Atomics

/// Per-recording nonblocking counters; freshness is not a speech classification.
final class AudioTapDiagnostics: @unchecked Sendable {
    static func lossLabel(_ count: UInt64?) -> String { count.map(String.init) ?? "未知" }
    private let last = ManagedAtomic<UInt64>(0)
    private let buffers = ManagedAtomic<UInt64>(0)
    private let losses = ManagedAtomic<UInt64>(0)
    func accept(at time: UInt64) {
        _ = buffers.wrappingIncrementThenLoad(ordering: .relaxed)
        last.store(time, ordering: .releasing)
    }
    func lost() { _ = losses.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing) }
    func snapshot(now: UInt64) -> (buffers: UInt64, losses: UInt64, fresh: Bool) {
        let count = buffers.load(ordering: .acquiring)
        let loss = losses.load(ordering: .acquiring)
        let stamp = last.load(ordering: .acquiring)
        return (count, loss, count > 0 && loss == 0 && now >= stamp && now - stamp <= 500_000_000)
    }
}

/// Conservative observation: an uncertain signal is never classified as silence.
struct AudioActivityState {
    enum Status: Equatable { case active, unknown }
    private var lastTime: TimeInterval?
    private var lastStatus: Status = .unknown

    mutating func observe(level: Float, at time: TimeInterval) {
        guard time.isFinite, level.isFinite, level >= 0,
              lastTime.map({ time >= $0 }) ?? true else { lost(); return }
        lastTime = time
        lastStatus = level >= 0.015 ? .active : .unknown
    }

    mutating func lost() { lastTime = nil; lastStatus = .unknown }

    func status(now: TimeInterval) -> Status {
        guard let lastTime, now.isFinite, now >= lastTime, now - lastTime <= 0.5 else { return .unknown }
        return lastStatus
    }
}
