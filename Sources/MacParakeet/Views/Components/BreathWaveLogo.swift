import SwiftUI

/// MacParakeet's "Cursive P" / Breath Wave brand mark, rendered as pure
/// SwiftUI vector geometry. Single source of truth for the canonical 128×128
/// viewBox lives in `BreathWaveIcon.appIcon` (Core Graphics, used by the dock
/// icon) and `docs/brand-identity.md`; this view ports those exact points so
/// the inline SwiftUI mark and the dock icon stay perfectly in sync.
///
/// ## Why a Canvas instead of `Circle().stroke()` + offsets
/// The bowl, dot, and tail share one coordinate system (the 128 viewBox). A
/// Canvas lets us declare them with the canonical numbers, then apply one
/// fit-to-frame transform — instead of computing per-shape offsets that drift
/// out of sync with the spec the moment someone tweaks geometry.
///
/// ## Why the visual-bounds fit
/// The canonical glyph is *not* centered in its 128 viewBox: the bowl sits
/// upper-right, the cursive tail loops lower-left. A naïve `size/128` scale
/// would bias the mark toward the upper-right of any tight frame. We compute
/// the visual content bounds (including stroke half-width) and fit those into
/// the frame, so the mark reads as visually centered in slots like the 16pt
/// `AssistantHead` column.
///
/// ## Sizing guidance (per `docs/brand-identity.md`)
/// 16px is the documented legibility floor. At ≤32pt this view uses the
/// "small" stroke spec (10) and dot radius (8) for legibility — matches the
/// menu bar variant. Below 14pt the mark gets muddy; consider the
/// dock-icon-style padded version or a different glyph instead.
struct BreathWaveLogo: View {
    var size: CGFloat = 16
    var tint: Color = DesignSystem.Colors.accent
    var opacity: Double = 1.0

    /// Visual content bounds within the canonical 128×128 viewBox, including
    /// stroke half-width. Bowl spans roughly (42,8)–(94,60); tail descends to
    /// y≈114 and reaches x≈8 on the left. Hard-coded so the fit math is a
    /// constant — geometry only changes if `BreathWaveIcon.appIcon` changes.
    private let visualBounds = CGRect(x: 3, y: 3, width: 96, height: 116)

    /// Brand-spec small-size stroke and dot. See `docs/brand-identity.md`
    /// table; reused for any rendered size ≤32pt.
    private let strokeWidth: CGFloat = 10
    private let dotRadius: CGFloat = 8

    var body: some View {
        Canvas { context, canvasSize in
            // Fit visual bounds into the frame, preserving aspect, centered.
            let scale = min(
                canvasSize.width / visualBounds.width,
                canvasSize.height / visualBounds.height
            )
            let scaledWidth = visualBounds.width * scale
            let scaledHeight = visualBounds.height * scale
            let offsetX = (canvasSize.width - scaledWidth) / 2 - visualBounds.minX * scale
            let offsetY = (canvasSize.height - scaledHeight) / 2 - visualBounds.minY * scale

            context.transform = CGAffineTransform(translationX: offsetX, y: offsetY)
                .scaledBy(x: scale, y: scale)

            let inkColor = GraphicsContext.Shading.color(tint.opacity(opacity))

            // Bowl — stroked circle, center (68,34), r=26
            var bowl = Path()
            bowl.addArc(
                center: CGPoint(x: 68, y: 34),
                radius: 26,
                startAngle: .zero,
                endAngle: .degrees(360),
                clockwise: false
            )
            context.stroke(bowl, with: inkColor, lineWidth: strokeWidth)

            // Stem + cursive loop tail — three cubic curves from (42,34) down
            // to (42,82), looping under to (18,112), back up-left to (8,98),
            // and around to (42,92). Round caps soften the open ends.
            var tail = Path()
            tail.move(to: CGPoint(x: 42, y: 34))
            tail.addLine(to: CGPoint(x: 42, y: 82))
            tail.addCurve(
                to: CGPoint(x: 18, y: 112),
                control1: CGPoint(x: 42, y: 100),
                control2: CGPoint(x: 30, y: 110)
            )
            tail.addCurve(
                to: CGPoint(x: 8, y: 98),
                control1: CGPoint(x: 6, y: 114),
                control2: CGPoint(x: 2, y: 106)
            )
            tail.addCurve(
                to: CGPoint(x: 42, y: 92),
                control1: CGPoint(x: 14, y: 90),
                control2: CGPoint(x: 30, y: 88)
            )
            context.stroke(
                tail,
                with: inkColor,
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
            )

            // Dot — filled, same center as bowl
            var dot = Path()
            dot.addArc(
                center: CGPoint(x: 68, y: 34),
                radius: dotRadius,
                startAngle: .zero,
                endAngle: .degrees(360),
                clockwise: false
            )
            context.fill(dot, with: inkColor)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
