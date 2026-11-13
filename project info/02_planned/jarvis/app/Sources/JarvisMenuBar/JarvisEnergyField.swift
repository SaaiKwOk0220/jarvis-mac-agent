import SwiftUI

/// Ambient state visualization. Motion is generative and is not an audio meter.
struct JarvisEnergyField: View {
    enum State: Equatable {
        case idle, listening, thinking, speaking

        fileprivate var palette: Palette {
            switch self {
            case .idle: return Palette(primary: Color(red: 0.08, green: 0.63, blue: 0.80), accent: Color(red: 0.34, green: 0.96, blue: 1), speed: 0.12, amplitude: 0.74, intensity: 0.76)
            case .listening: return Palette(primary: Color(red: 0.08, green: 0.84, blue: 0.91), accent: Color(red: 0.72, green: 1, blue: 0.93), speed: 0.24, amplitude: 1.05, intensity: 1)
            case .thinking: return Palette(primary: Color(red: 0.20, green: 0.55, blue: 0.98), accent: Color(red: 0.63, green: 0.76, blue: 1), speed: 0.31, amplitude: 1.18, intensity: 0.93)
            case .speaking: return Palette(primary: Color(red: 0.08, green: 0.79, blue: 0.88), accent: Color(red: 1, green: 0.79, blue: 0.48), speed: 0.20, amplitude: 0.93, intensity: 1.08)
            }
        }
    }

    fileprivate struct Palette {
        let primary: Color
        let accent: Color
        let speed: Double
        let amplitude: Double
        let intensity: Double
    }

    let state: State
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * state.palette.speed
                drawField(context: &context, size: size, time: time, palette: state.palette)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func drawField(context: inout GraphicsContext, size: CGSize, time: Double, palette: Palette) {
        guard size.width > 1, size.height > 1 else { return }
        let w = Double(size.width), h = Double(size.height)
        let core = CGPoint(x: w * 0.53, y: h * 0.51)
        let shortSide = min(w, h)
        var light = context
        light.blendMode = .screen

        // A broad, asymmetric atmosphere binds the field to the surrounding space.
        let atmosphere = Path(ellipseIn: CGRect(x: w * 0.09, y: h * 0.08, width: w * 0.82, height: h * 0.84))
        light.fill(atmosphere, with: .radialGradient(Gradient(colors: [palette.primary.opacity(0.23 * palette.intensity), palette.primary.opacity(0.08), .clear]), center: core, startRadius: 0, endRadius: shortSide * 0.55))

        // Long, layered wavefronts flow across the canvas, rather than orbiting a sphere.
        // Width, parallax and glow vary per layer so foreground cuts across background.
        for layer in 0..<34 {
            let z = Double(layer) / 33
            let seed = Double(layer + 1)
            let drift = time * (layer.isMultiple(of: 3) ? -0.55 : 0.72)
            let baseY = 0.50 + (z - 0.5) * 0.43
            let waveHeight = (0.045 + 0.075 * fract(seed * 0.618)) * palette.amplitude
            let angle = seed * 1.37 + drift
            let left = 0.025 + 0.10 * fract(seed * 0.29)
            let right = 0.875 + 0.10 * fract(seed * 0.43)
            var ribbon = Path()
            for step in 0...90 {
                let t = Double(step) / 90
                let x = left + (right - left) * t
                let arch = sin(.pi * t)
                let bend = sin(t * .pi * 2.1 + angle) * waveHeight * (0.32 + 0.68 * arch)
                let sweep = (t - 0.5) * (z - 0.43) * 0.28
                let pinch = (baseY - 0.5) * (1 - 0.48 * exp(-pow((t - 0.53) / 0.19, 2)))
                let y = 0.5 + pinch + bend + sweep
                let point = CGPoint(x: w * x, y: h * max(0.075, min(0.925, y)))
                if step == 0 { ribbon.move(to: point) } else { ribbon.addLine(to: point) }
            }
            let color = layer.isMultiple(of: 7) ? palette.accent : palette.primary
            let depth = 0.30 + z * 0.70
            let gradient = Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: color.opacity(0.18 * depth * palette.intensity), location: 0.20),
                .init(color: color.opacity((0.40 + z * 0.28) * palette.intensity), location: 0.52),
                .init(color: color.opacity(0.16 * depth * palette.intensity), location: 0.82),
                .init(color: .clear, location: 1)
            ])
            let start = CGPoint(x: w * left, y: h * 0.5), end = CGPoint(x: w * right, y: h * 0.5)
            var bloom = light
            bloom.addFilter(.blur(radius: 4 + z * 7))
            bloom.stroke(ribbon, with: .linearGradient(gradient, startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: 7 + z * 14, lineCap: .round, lineJoin: .round))
            light.stroke(ribbon, with: .linearGradient(gradient, startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: 0.7 + z * 1.5, lineCap: .round, lineJoin: .round))
        }

        // Diagonal translucent curtains add near/far structure behind the core.
        for layer in 0..<7 {
            let k = Double(layer), shift = sin(time * 0.38 + k) * 0.025
            var curtain = Path()
            curtain.move(to: CGPoint(x: w * (0.12 + k * 0.035), y: h * 0.78))
            curtain.addCurve(to: CGPoint(x: w * (0.85 - k * 0.025), y: h * 0.18), control1: CGPoint(x: w * (0.34 + shift), y: h * (0.84 - k * 0.03)), control2: CGPoint(x: w * (0.65 - shift), y: h * (0.18 + k * 0.035)))
            var haze = light
            haze.addFilter(.blur(radius: 8 + k))
            haze.stroke(curtain, with: .color(palette.primary.opacity(0.035 * palette.intensity)), style: StrokeStyle(lineWidth: 12 + k * 3, lineCap: .round))
            light.stroke(curtain, with: .color(palette.accent.opacity(0.065 * palette.intensity)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }

        // Two offset light sources prevent a flat, perfectly centered disc.
        let bloomRadius = shortSide * 0.26
        let corePath = Path(ellipseIn: CGRect(x: core.x - bloomRadius, y: core.y - bloomRadius, width: bloomRadius * 2, height: bloomRadius * 2))
        light.fill(corePath, with: .radialGradient(Gradient(colors: [.white.opacity(0.90 * min(1, palette.intensity)), palette.accent.opacity(0.52 * palette.intensity), palette.primary.opacity(0.20), .clear]), center: core, startRadius: 0, endRadius: bloomRadius))
        let secondary = CGPoint(x: w * 0.39, y: h * 0.59)
        let secondaryRadius = shortSide * 0.17
        let secondaryPath = Path(ellipseIn: CGRect(x: secondary.x - secondaryRadius, y: secondary.y - secondaryRadius, width: secondaryRadius * 2, height: secondaryRadius * 2))
        light.fill(secondaryPath, with: .radialGradient(Gradient(colors: [palette.primary.opacity(0.28 * palette.intensity), .clear]), center: secondary, startRadius: 0, endRadius: secondaryRadius))

        // Deterministic particles form a receding dust curtain, with no sensor input.
        for particle in 0..<160 {
            let i = Double(particle + 1)
            let x = 0.035 + 0.93 * fract(i * 0.61803398875 + time * (particle.isMultiple(of: 2) ? 0.015 : -0.009))
            let ySeed = fract(i * 0.754877666)
            let y = 0.11 + 0.78 * ySeed
            let distance = abs(x - 0.53) + abs(y - 0.51) * 0.65
            let alpha = max(0.03, 0.46 - distance * 0.30) * (0.35 + 0.65 * fract(i * 0.371)) * palette.intensity
            let dotRadius = 0.35 + 1.35 * fract(i * 0.41421356)
            let dot = Path(ellipseIn: CGRect(x: w * x - dotRadius, y: h * y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
            light.fill(dot, with: .color((particle.isMultiple(of: 11) ? palette.accent : palette.primary).opacity(alpha)))
        }
        context = light
    }

    private func fract(_ value: Double) -> Double { value - floor(value) }
}
