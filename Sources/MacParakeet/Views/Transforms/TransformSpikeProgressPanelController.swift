import AppKit
import MacParakeetCore
import SwiftUI

/// Non-activating panel that hosts the Transforms spike progress UI. Spike
/// scope only — see `docs/research/transforms-design-2026-05.md` for the
/// production design (custom loader / pill anchored near the trigger context).
///
/// NSPanel notes:
/// - `canBecomeKey` is `false` so triggering the hotkey doesn't yank focus
///   from the user's frontmost app (which is the whole point — we paste back
///   into their text field).
/// - `.nonactivatingPanel | .borderless` matches the dictation + meeting
///   recording pill chrome elsewhere in the app.
private final class TransformsSpikePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Tiny state object the panel binds to. ObservableObject (not @Observable)
/// because the spike supports macOS 14 and the older binding still works
/// reliably for one-shot panels.
@MainActor
final class TransformSpikeProgressViewModel: ObservableObject {
    @Published var label: String = "Polishing…"
    @Published var phase: Phase = .working

    enum Phase: Equatable {
        case working
        case done(message: String)
        case failed(message: String)
    }
}

@MainActor
final class TransformSpikeProgressPanelController {
    private var panel: NSPanel?
    private var viewModel: TransformSpikeProgressViewModel?
    private var autoDismissTask: Task<Void, Never>?

    /// Open (or reuse) the panel showing the in-progress label. Idempotent —
    /// calling `show` while a panel is visible just resets state.
    func show(label: String = "Polishing…") {
        autoDismissTask?.cancel()
        autoDismissTask = nil

        if let viewModel {
            viewModel.label = label
            viewModel.phase = .working
            return
        }

        let vm = TransformSpikeProgressViewModel()
        vm.label = label
        self.viewModel = vm

        let host = NSHostingView(rootView: TransformSpikeProgressView(viewModel: vm))
        let initialSize = NSSize(width: 220, height: 64)
        host.frame = NSRect(origin: .zero, size: initialSize)

        let panel = TransformsSpikePanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // SwiftUI renders its own shadow via cardShadow.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.alphaValue = 0

        let panelSize = host.fittingSize.width > 0 ? host.fittingSize : initialSize
        if let screen = Self.screenForPanel() {
            let visible = screen.visibleFrame
            let x = visible.midX - panelSize.width / 2
            let y = visible.maxY - panelSize.height - 24
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: true)
        }

        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Swap the loader for a "Done" affordance, auto-dismiss after 1.2s.
    func done(message: String = "Done") {
        guard let viewModel else { return }
        viewModel.phase = .done(message: message)
        scheduleAutoDismiss(after: .milliseconds(1200))
    }

    /// Swap the loader for an error affordance, auto-dismiss after 4s.
    func fail(message: String) {
        if viewModel == nil {
            // Spike-grade: surface the error briefly even if show() never ran.
            show(label: "Transforms")
        }
        viewModel?.phase = .failed(message: message)
        scheduleAutoDismiss(after: .milliseconds(4000))
    }

    /// Tear the panel down with a brief fade. Cancel-then-restart from the
    /// coordinator goes through `show()`, not `close()`, so this is reserved
    /// for terminal dismissal.
    func close() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let panelRef = panel else { return }
        panel = nil
        viewModel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        }, completionHandler: {
            panelRef.orderOut(nil)
        })
    }

    private func scheduleAutoDismiss(after delay: Duration) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private static func screenForPanel() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - View

private struct TransformSpikeProgressView: View {
    @ObservedObject var viewModel: TransformSpikeProgressViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            indicator
                .frame(width: 22, height: 22)
                .id(indicatorIdentity)
                .transition(
                    .scale(scale: 0.65, anchor: .center)
                        .combined(with: .opacity)
                )

            Text(currentLabel)
                .font(DesignSystem.Typography.meetingPillStatus)
                .foregroundStyle(DesignSystem.Colors.meetingPillText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .id(labelIdentity)
                .transition(.opacity)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignSystem.Colors.meetingPillBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DesignSystem.Colors.meetingPillStroke, lineWidth: 0.5)
        )
        .cardShadow(DesignSystem.Shadows.meetingPill)
        .padding(10)  // give the SwiftUI shadow room inside the NSPanel frame
        .animation(.easeInOut(duration: 0.24), value: phaseIdentity)
    }

    @ViewBuilder
    private var indicator: some View {
        switch viewModel.phase {
        case .working:
            BezierScribeLoader(tint: DesignSystem.Colors.accent, paused: reduceMotion)
        case .done:
            RingCheckmarkView(tint: DesignSystem.Colors.successGreen)
        case .failed:
            FailingTriangleView(tint: DesignSystem.Colors.warningAmber)
        }
    }

    private var currentLabel: String {
        switch viewModel.phase {
        case .working: return viewModel.label
        case .done(let message): return message
        case .failed(let message): return message
        }
    }

    private var indicatorIdentity: String {
        switch viewModel.phase {
        case .working: return "working"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private var labelIdentity: String {
        currentLabel
    }

    private var phaseIdentity: Int {
        switch viewModel.phase {
        case .working: return 0
        case .done: return 1
        case .failed: return 2
        }
    }
}

// MARK: - Bezier Scribe Loader

/// A continuous coral curve traces a closed lissajous, head leading a fading
/// tail — reads as "writing itself" rather than "spinning." Picked over a stock
/// `ProgressView()` per `docs/research/transforms-design-2026-05.md` —
/// Transforms is a writing/refinement surface that earns its own motion
/// vocabulary, distinct from the dictation overlay's Merkaba and the meeting
/// pill's rosette.
///
/// Implementation: TimelineView drives a 60Hz Canvas that walks a parametric
/// curve. Each frame draws short line segments behind a moving "head," with
/// alpha + width tapering toward the tail. The closed lissajous has no hard
/// loop seam — the user can watch for two seconds or eight without seeing a
/// repeat point.
private struct BezierScribeLoader: View {
    var tint: Color
    var paused: Bool = false
    var period: Double = 2.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let t = (now.truncatingRemainder(dividingBy: period)) / period
                Self.drawScribe(in: ctx, size: size, t: t, tint: tint)
            }
        }
    }

    private static func drawScribe(in ctx: GraphicsContext, size: CGSize, t: Double, tint: Color) {
        let segments = 28
        let trailArc = 0.5  // fraction of full period rendered behind the head
        let baseLineWidth: CGFloat = 1.6

        for i in 0..<segments {
            let frac = Double(i) / Double(segments - 1)
            let nextFrac = Double(i + 1) / Double(segments - 1)
            let phaseA = t - frac * trailArc
            let phaseB = t - nextFrac * trailArc

            let pA = point(phase: phaseA, size: size)
            let pB = point(phase: phaseB, size: size)

            var p = Path()
            p.move(to: pA)
            p.addLine(to: pB)

            let alpha = pow(1.0 - frac, 1.35)
            let width = baseLineWidth * (1.0 - frac * 0.4)

            ctx.stroke(
                p,
                with: .color(tint.opacity(alpha)),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }

        // Bright head dot — gives the curve a clear "now" point.
        let head = point(phase: t, size: size)
        let dotR: CGFloat = 1.6
        let dotRect = CGRect(x: head.x - dotR, y: head.y - dotR, width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(tint))
    }

    /// Lissajous-derived parametric: x = sin(θ)·cos(θ/2), y = sin(2θ).
    /// Asymmetric frequency ratio yields a soft figure-8 that feels like a
    /// hand drawing through a glyph rather than tracing a circle.
    private static func point(phase: Double, size: CGSize) -> CGPoint {
        let theta = phase * 2 * .pi
        let cx = size.width / 2
        let cy = size.height / 2
        let rx = size.width * 0.40
        let ry = size.height * 0.30
        let x = cx + rx * sin(theta) * cos(theta * 0.5)
        let y = cy + ry * sin(theta * 2)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Ring Checkmark (Done state)

/// Apple-Pay style: ring strokes around, then the check strokes in. Borrowed
/// shape from `MeetingRecordingPillView.MeetingCompletionCheckmarkView` but
/// sized for the Transforms 22pt indicator slot.
private struct RingCheckmarkView: View {
    var tint: Color
    @State private var ringTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0

    private let lineWidth: CGFloat = 1.4

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.20), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .padding(6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.32)) {
                ringTrim = 1
            }
            withAnimation(.easeOut(duration: 0.22).delay(0.24)) {
                checkTrim = 1
            }
        }
    }

    private struct CheckmarkShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let w = rect.width
            let h = rect.height
            path.move(to: CGPoint(x: w * 0.22, y: h * 0.52))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.72))
            path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.28))
            return path
        }
    }
}

// MARK: - Failing Triangle (Fail state)

/// Triangle outline strokes in, then a centered bang fades up. Keeps the
/// affordance warm (amber, not red) — failures are recoverable, the user just
/// needs to retry or fix configuration.
private struct FailingTriangleView: View {
    var tint: Color
    @State private var triangleTrim: CGFloat = 0
    @State private var bangOpacity: Double = 0

    var body: some View {
        ZStack {
            TriangleShape()
                .trim(from: 0, to: triangleTrim)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            Text("!")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .opacity(bangOpacity)
                .offset(y: 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.32)) {
                triangleTrim = 1
            }
            withAnimation(.easeOut(duration: 0.20).delay(0.22)) {
                bangOpacity = 1
            }
        }
    }

    private struct TriangleShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let inset: CGFloat = 1
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
            path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
            path.closeSubpath()
            return path
        }
    }
}
