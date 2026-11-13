import Foundation

/// Offline-only input; no audio or text is retained by this evaluator.
struct VADFrame {
    let samples: [Float]
    let sampleRate: Double
    var duration: Double { Double(samples.count) / sampleRate }
    var level: Float {
        guard !samples.isEmpty else { return 0 }
        return Float((samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot())
    }
}

protocol VADCandidate {
    mutating func observe(_ frame: VADFrame) -> Bool
}

/// Baseline for comparisons; this energy heuristic is not a speech classifier.
struct EnergyVADCandidate: VADCandidate {
    private var detector: SpeechPauseDetector
    init(pauseDuration: Double) { detector = SpeechPauseDetector(pauseDuration: pauseDuration) }
    mutating func observe(_ frame: VADFrame) -> Bool {
        detector.observe(level: frame.level, duration: frame.duration)
    }
}

struct VADEvaluationReport {
    let endpointSeconds: Double?
    let framesProcessed: Int
}

enum VADEvaluator {
    static func evaluate<C: VADCandidate>(_ frames: [VADFrame], using candidate: C) -> VADEvaluationReport {
        var candidate = candidate
        var elapsed = 0.0
        for (index, frame) in frames.enumerated() {
            guard frame.sampleRate.isFinite, frame.sampleRate > 0, !frame.samples.isEmpty, frame.samples.allSatisfy(\.isFinite) else { continue }
            elapsed += frame.duration
            if candidate.observe(frame) { return .init(endpointSeconds: elapsed, framesProcessed: index + 1) }
        }
        return .init(endpointSeconds: nil, framesProcessed: frames.count)
    }
}
