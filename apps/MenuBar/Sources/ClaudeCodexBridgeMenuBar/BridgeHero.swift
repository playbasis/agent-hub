import BridgeCore
import SwiftUI

/// The panel's header: Claude and Codex as two identity discs joined by a
/// thin bridge line. The line brightens and carries a few particles toward
/// whichever agent is working; the words beneath confirm the state.
struct BridgeHero: View {
    @ObservedObject var model: BridgeViewModel
    var claudeLinked: Bool
    var codexLinked: Bool

    private var activeAgent: AgentName {
        guard model.isReady else { return .none }
        return [.running, .thinking].contains(model.status.state) ? model.status.activeAgent : .none
    }

    private var isThinking: Bool { model.isReady && model.status.state == .thinking }
    private var isFlowing: Bool { activeAgent != .none || isThinking }

    private var flowDirection: Double {
        switch activeAgent {
        case .codex: return 1
        case .claude: return -1
        default: return isThinking ? 1 : 0
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                agentColumn("Claude", agent: .claude, linked: claudeLinked)
                BridgeLine(
                    flowing: isFlowing,
                    direction: flowDirection,
                    thinking: isThinking,
                    paused: [.paused, .parked].contains(model.status.state)
                )
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                agentColumn("Codex", agent: .codex, linked: codexLinked)
            }
            .padding(.horizontal, 22)

            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.statusLabel)
                        .font(BridgeFont.title)
                        .foregroundStyle(BridgeTheme.textPrimary)
                    if let remaining = model.remainingText {
                        Text("· \(remaining) left")
                            .font(BridgeFont.secondary.monospacedDigit())
                            .foregroundStyle(BridgeTheme.textSecondary)
                    }
                }
                StatusDot(text: model.isReady ? "Connected · \(BridgeBrand.shortName)" : model.connectionLabel, color: model.connectionColor, font: BridgeFont.secondary)
            }
            .animation(.easeInOut(duration: 0.2), value: model.statusLabel)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.statusLabel). \(model.connectionLabel)")
    }

    private func agentColumn(_ name: String, agent: AgentName, linked: Bool) -> some View {
        VStack(spacing: 6) {
            AgentAvatar(name: name, size: 34, active: activeAgent == agent, thinking: activeAgent == agent, dimmed: !linked)
            Text(name)
                .font(BridgeFont.captionMedium)
                .foregroundStyle(activeAgent == agent ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
        }
        .frame(width: 64)
    }
}

/// The line between the two discs, drawn with Canvas so it costs nothing at
/// rest and stays smooth when live.
struct BridgeLine: View {
    var flowing: Bool
    var direction: Double
    var thinking: Bool
    var paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40, paused: !flowing || BridgeTheme.reduceMotion)) { context in
            Canvas { canvas, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let start = CGPoint(x: 0, y: size.height * 0.5)
                let end = CGPoint(x: size.width, y: size.height * 0.5)
                let control = CGPoint(x: size.width / 2, y: size.height * 0.92)
                var line = Path()
                line.move(to: start)
                line.addQuadCurve(to: end, control: control)

                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [BridgeTheme.claude, BridgeTheme.codex]),
                    startPoint: start, endPoint: end
                )
                if paused {
                    canvas.opacity = 0.6
                    canvas.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5]))
                    return
                }
                canvas.opacity = flowing ? 0.95 : 0.45
                canvas.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                guard flowing, !BridgeTheme.reduceMotion else { return }
                for index in 0 ..< 3 {
                    let phase = (t * 0.4 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                    let u = direction >= 0 ? phase : 1 - phase
                    let point = Self.quadPoint(u, start, control, end)
                    let radius = 1.6 + 0.9 * sin(phase * .pi)
                    canvas.opacity = 0.9
                    canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(.white))
                }
                if thinking {
                    let apex = Self.quadPoint(0.5, start, control, end)
                    let pulse = 0.5 + 0.5 * sin(t * 3)
                    canvas.opacity = 0.35 + 0.5 * pulse
                    canvas.fill(Path(ellipseIn: CGRect(x: apex.x - 3, y: apex.y - 3, width: 6, height: 6)), with: .color(.white))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func quadPoint(_ u: Double, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint) -> CGPoint {
        let v = 1 - u
        return CGPoint(
            x: v * v * p0.x + 2 * v * u * p1.x + u * u * p2.x,
            y: v * v * p0.y + 2 * v * u * p1.y + u * u * p2.y
        )
    }
}
