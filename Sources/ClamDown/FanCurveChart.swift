import SwiftUI
import ClamDownAppKit
import ClamDownShared
import ClamDownUI

/// The fan curve on the Cooling page: fan speed against the hottest temperature, with the safety floor, the speed the
/// fans run at now, and points that can be dragged or moved with the arrow keys.
///
/// The chart only draws and reports. Every move goes through `FanCurveEditor`, so a point stops at the same
/// limits here as anywhere else; while a point is dragged the chart shows the moved curve itself and reports
/// the move once, when the drag ends, so a drag does not save the settings and resend the policy on every step.
struct FanCurveChart: View {
    let points: [FanPoint]
    let mode: FanCurveMode
    /// The temperature the curve follows now: the hottest sensor. Nil hides the "Now" mark.
    let nowTemperature: Double?
    /// Gives the right-hand rpm scale and the rpm in the drag label. Nil leaves them out.
    let firstFan: FanReading?
    /// Debug pictures only: shows this point's label as if it were being dragged.
    let labelledPoint: Int?
    let onMove: (Int, FanPoint) -> Void

    /// The curve while a point is being dragged or a move waits for the settings to change.
    @State private var draft: [FanPoint]?
    @State private var dragging: Int?
    /// Where the pointer took hold of the handle, from its centre, so the point does not jump to the pointer.
    @State private var grabOffset: CGSize = .zero
    @FocusState private var focused: Int?
    /// Arrow-key moves show at once but are reported only after a pause in key presses, or when the point loses
    /// focus: each report saves the settings and sends the helper a new policy.
    @State private var keyMoves = EditCommitter<KeyMove>()

    private struct KeyMove {
        let index: Int
        let point: FanPoint
    }

    init(points: [FanPoint], mode: FanCurveMode, nowTemperature: Double?, firstFan: FanReading?,
         labelledPoint: Int? = nil, onMove: @escaping (Int, FanPoint) -> Void) {
        self.points = points
        self.mode = mode
        self.nowTemperature = nowTemperature
        self.firstFan = firstFan
        self.labelledPoint = labelledPoint
        self.onMove = onMove
    }

    private static let space = "fanCurveChart"
    private static let topMargin: CGFloat = 24
    private static let bottomMargin: CGFloat = 38
    private static let leftMargin: CGFloat = 46
    private static let hatchSpacing: CGFloat = 7

    private var shown: [FanPoint] { draft ?? points }

    var body: some View {
        GeometryReader { proxy in
            let plot = Plot(size: proxy.size, rightMargin: rpmScale == nil ? 22 : 50,
                            top: Self.topMargin, bottom: Self.bottomMargin, left: Self.leftMargin)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context, plot: plot) }
                    .accessibilityHidden(true)
                ForEach(shown.indices, id: \.self) { index in
                    handle(index, plot: plot)
                }
                if let index = dragging ?? labelledPoint, shown.indices.contains(index) {
                    dragLabel(for: shown[index], plot: plot)
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .frame(height: Self.topMargin + CDMetric.chartHeight + Self.bottomMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Fan curve over the hottest temperature"))
        // A waiting key move keeps its draft: the settings have not caught up with it yet.
        .onChange(of: points) { _ in if dragging == nil, keyMoves.pending == nil { draft = nil } }
        .onChange(of: mode) { _ in
            // The waiting move belongs to the other mode's curve.
            keyMoves.discard()
            draft = nil
            dragging = nil
        }
        .onChange(of: focused) { _ in keyMoves.flush() }
        .onDisappear { keyMoves.flush() }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, plot: Plot) {
        drawGrid(in: &context, plot: plot)
        drawFloor(in: &context, plot: plot)
        let policy = FanPolicy(points: shown).repaired()
        let temperatures = Self.sampleTemperatures(adding: shown)
        let heat = GraphicsContext.Shading.linearGradient(
            Gradient(stops: CDColor.chartHeatStops),
            startPoint: CGPoint(x: plot.x(Plot.coolest), y: 0), endPoint: CGPoint(x: plot.x(Plot.hottest), y: 0))

        var line = Path()
        for (offset, temperature) in temperatures.enumerated() {
            let point = plot.point(temperature, policy.speed(at: temperature))
            if offset == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        var area = line
        area.addLine(to: plot.point(Plot.hottest, 0))
        area.addLine(to: plot.point(Plot.coolest, 0))
        area.closeSubpath()
        var fill = context
        fill.opacity = 0.2
        fill.fill(area, with: heat)

        // Where the floor lifts the fans above the curve, what the curve asked for is a thin dashed line.
        var asked = Path()
        var open = false
        for (from, to) in zip(temperatures, temperatures.dropFirst()) {
            let under = policy.curveSpeed(at: to) < SafetyFloor.speed(at: to) - 0.5
            if under {
                if !open { asked.move(to: plot.point(from, policy.curveSpeed(at: from))) }
                asked.addLine(to: plot.point(to, policy.curveSpeed(at: to)))
            }
            open = under
        }
        context.stroke(asked, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        context.stroke(line, with: heat,
                       style: StrokeStyle(lineWidth: CDMetric.chartLineWidth, lineCap: .round, lineJoin: .round))

        if let now = nowTemperature {
            drawNow(now, policy: policy, in: &context, plot: plot)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, plot: Plot) {
        var grid = Path()
        for temperature in stride(from: Plot.coolest, through: Plot.hottest, by: 10) {
            grid.move(to: plot.point(temperature, 0))
            grid.addLine(to: plot.point(temperature, 100))
            context.draw(axisText(String(localized: "\(Int(temperature)) \u{00B0}C")),
                         at: CGPoint(x: plot.x(temperature), y: plot.rect.maxY + 12), anchor: .center)
        }
        context.draw(axisText(String(localized: "Hottest temperature")),
                     at: CGPoint(x: plot.rect.midX, y: plot.rect.maxY + 29), anchor: .center)
        for speed in [0.0, 25, 50, 75, 100] {
            grid.move(to: plot.point(Plot.coolest, speed))
            grid.addLine(to: plot.point(Plot.hottest, speed))
            let label = speed == 0 ? String(localized: "min")
                : speed == 100 ? String(localized: "max") : String(localized: "\(Int(speed)) %")
            // Clear of a handle at the left edge, where the Standard curve's first point sits by default.
            context.draw(axisText(label), at: CGPoint(x: plot.rect.minX - 12, y: plot.y(speed)), anchor: .trailing)
        }
        context.stroke(grid, with: .color(CDColor.chartGrid), lineWidth: 1)

        if let scale = rpmScale {
            for speed in [0.0, 50, 100] {
                context.draw(axisText(Self.rpmText(scale.rpm(at: speed))),
                             at: CGPoint(x: plot.rect.maxX + 6, y: plot.y(speed)), anchor: .leading)
            }
            context.draw(axisText(String(localized: "rpm")), at: CGPoint(x: plot.rect.maxX + 6, y: plot.rect.minY - 12), anchor: .leading)
        }
    }

    /// The floor's zone, from where it starts to rise to the hot end, in grey with a hatch.
    private func drawFloor(in context: inout GraphicsContext, plot: Plot) {
        var zone = Path()
        zone.move(to: plot.point(Double(SafetyFloor.rampStart), 0))
        zone.addLine(to: plot.point(Double(SafetyFloor.rampEnd), 100))
        zone.addLine(to: plot.point(Plot.hottest, 100))
        zone.addLine(to: plot.point(Plot.hottest, 0))
        zone.closeSubpath()
        context.fill(zone, with: .color(CDColor.chartZone))
        context.drawLayer { layer in
            layer.clip(to: zone)
            let bounds = zone.boundingRect
            var hatch = Path()
            var x = bounds.minX - bounds.height
            while x < bounds.maxX {
                hatch.move(to: CGPoint(x: x, y: bounds.maxY))
                hatch.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
                x += Self.hatchSpacing
            }
            layer.stroke(hatch, with: .color(CDColor.chartZoneInk.opacity(0.45)), lineWidth: 1)
        }
        context.draw(Text("Safety floor").font(.caption2.weight(.medium)).foregroundColor(CDColor.chartZoneInk),
                     at: CGPoint(x: plot.x(Plot.hottest) - 6, y: plot.y(9)), anchor: .trailing)
    }

    private func drawNow(_ temperature: Double, policy: FanPolicy, in context: inout GraphicsContext, plot: Plot) {
        // A Mac cooler than 40 °C runs at the curve's left end: the mark stays at the edge with the true value.
        let shownAt = min(max(temperature, Plot.coolest), Plot.hottest)
        let x = plot.x(shownAt)
        var line = Path()
        line.move(to: CGPoint(x: x, y: plot.rect.minY))
        line.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
        context.stroke(line, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        let dot = plot.point(shownAt, policy.speed(at: shownAt))
        let radius: CGFloat = 4.5
        let circle = Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(.primary))
        context.stroke(circle, with: .color(CDColor.cardBackground), lineWidth: 1.5)
        let label = Text("Now \(Int(temperature.rounded())) \u{00B0}C").font(.caption2.weight(.semibold)).monospacedDigit()
        let labelX = min(max(x, plot.rect.minX + 26), plot.rect.maxX - 26)
        context.draw(label, at: CGPoint(x: labelX, y: plot.rect.minY - 12), anchor: .center)
    }

    private func axisText(_ text: String) -> Text {
        Text(text).font(.caption2).monospacedDigit().foregroundColor(.secondary)
    }

    /// Every half degree, and each point's own temperature so that corners and steps are drawn where they are.
    private static func sampleTemperatures(adding points: [FanPoint]) -> [Double] {
        let steps = stride(from: Plot.coolest, through: Plot.hottest, by: 0.5)
        let corners = points.map { Double($0.temperature) }
            + [Double(SafetyFloor.rampStart), Double(SafetyFloor.rampEnd)]
        return Array(Set(steps).union(corners)).sorted()
    }

    // MARK: - Handles

    private func handle(_ index: Int, plot: Plot) -> some View {
        let point = shown[index]
        let isActive = dragging == index || focused == index
        let fraction = (Double(point.temperature) - Plot.coolest) / (Plot.hottest - Plot.coolest)
        return Circle()
            .fill(CDColor.chartHandle)
            .overlay(Circle().strokeBorder(CDColor.chartHeat(at: fraction), lineWidth: isActive ? 3.5 : 2.5))
            .frame(width: CDMetric.chartHandleRadius * 2, height: CDMetric.chartHandleRadius * 2)
            .frame(width: CDMetric.chartHandleHitSize, height: CDMetric.chartHandleHitSize)
            .contentShape(Circle())
            .focusable()
            .focused($focused, equals: index)
            .onMoveCommand { nudge(index, $0) }
            .gesture(drag(index, plot: plot))
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Point \(index + 1)"))
            .accessibilityValue(String(localized: "\(point.temperature) degrees, \(point.speed) percent"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(index, .right)
                case .decrement: nudge(index, .left)
                @unknown default: break
                }
            }
            .accessibilityAction(named: String(localized: "Raise Speed")) { nudge(index, .up) }
            .accessibilityAction(named: String(localized: "Lower Speed")) { nudge(index, .down) }
            .position(plot.point(Double(point.temperature), Double(point.speed)))
    }

    private func drag(_ index: Int, plot: Plot) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard points.indices.contains(index) else { return }
                // Values are worked out locally: state written in this handler is not read back in it.
                let base: [FanPoint]
                let offset: CGSize
                if dragging != index {
                    // A new drag starts from the saved curve, or from a key move that is still on its way.
                    base = keyMoves.pending == nil ? points : shown
                    keyMoves.flush()
                    let center = plot.point(Double(points[index].temperature), Double(points[index].speed))
                    offset = CGSize(width: value.startLocation.x - center.x, height: value.startLocation.y - center.y)
                    grabOffset = offset
                    dragging = index
                    focused = index
                } else {
                    base = shown
                    offset = grabOffset
                }
                let location = CGPoint(x: value.location.x - offset.width, y: value.location.y - offset.height)
                let target = FanPoint(temperature: Int(plot.temperature(atX: location.x).rounded()),
                                      speed: Int(plot.speed(atY: location.y).rounded()))
                draft = FanCurveEditor.moved(base, mode: mode, dragging: index, to: target)
            }
            .onEnded { _ in
                dragging = nil
                guard let moved = draft, moved != points, moved.indices.contains(index) else {
                    draft = nil
                    return
                }
                // The draft stays on show until the settings bring the same curve back.
                onMove(index, moved[index])
            }
    }

    /// One step with an arrow key: 1 °C sideways or 1 % up or down, within the same limits as a drag.
    private func nudge(_ index: Int, _ direction: MoveCommandDirection) {
        let current = shown
        guard current.indices.contains(index) else { return }
        var target = current[index]
        switch direction {
        case .left: target.temperature -= 1
        case .right: target.temperature += 1
        case .up: target.speed += 1
        case .down: target.speed -= 1
        @unknown default: return
        }
        let moved = FanCurveEditor.moved(current, mode: mode, dragging: index, to: target)
        guard moved != current else { return }
        draft = moved
        // A move of another point (VoiceOver can adjust one without moving focus) is reported first.
        if let waiting = keyMoves.pending, waiting.index != index { keyMoves.flush() }
        let report = onMove
        keyMoves.submit(KeyMove(index: index, point: moved[index])) { report($0.index, $0.point) }
    }

    private func dragLabel(for point: FanPoint, plot: Plot) -> some View {
        var text = String(localized: "\(point.temperature) \u{00B0}C \u{00B7} \(point.speed) %")
        if let scale = rpmScale {
            let rpm = Self.rpmText(scale.rpm(at: Double(point.speed)))
            text = String(localized: "\(point.temperature) \u{00B0}C \u{00B7} \(point.speed) % \u{00B7} \(rpm) rpm")
        }
        let center = plot.point(Double(point.temperature), Double(point.speed))
        let above = center.y - 26
        return Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundColor(CDColor.cardBackground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: CDMetric.chartLabelRadius, style: .continuous).fill(Color.primary))
            .fixedSize()
            .position(x: min(max(center.x, 80), plot.size.width - 80), y: above < 10 ? center.y + 26 : above)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Scale

    /// The first fan's range, when it is known and is a range.
    private var rpmScale: RPMScale? {
        guard let fan = firstFan, fan.maximum > fan.minimum, fan.minimum >= 0 else { return nil }
        return RPMScale(minimum: fan.minimum, maximum: fan.maximum)
    }

    private struct RPMScale {
        let minimum: Double
        let maximum: Double

        /// The fan's speed at this percent of its range, to the nearest 10 rpm.
        func rpm(at percent: Double) -> Int {
            Int(((minimum + (maximum - minimum) * percent / 100) / 10).rounded()) * 10
        }
    }

    private static func rpmText(_ rpm: Int) -> String {
        rpm.formatted(.number.grouping(.automatic))
    }

    /// Where temperatures and speeds sit in the view.
    private struct Plot {
        static let coolest = Double(FanPolicy.temperatureRange.lowerBound)
        static let hottest = Double(FanPolicy.temperatureRange.upperBound)

        let size: CGSize
        let rect: CGRect

        init(size: CGSize, rightMargin: CGFloat, top: CGFloat, bottom: CGFloat, left: CGFloat) {
            self.size = size
            rect = CGRect(x: left, y: top, width: max(size.width - left - rightMargin, 1),
                          height: max(size.height - top - bottom, 1))
        }

        func x(_ temperature: Double) -> CGFloat {
            rect.minX + CGFloat((temperature - Self.coolest) / (Self.hottest - Self.coolest)) * rect.width
        }

        func y(_ speed: Double) -> CGFloat {
            rect.maxY - CGFloat(speed / 100) * rect.height
        }

        func point(_ temperature: Double, _ speed: Double) -> CGPoint {
            CGPoint(x: x(temperature), y: y(speed))
        }

        func temperature(atX x: CGFloat) -> Double {
            Self.coolest + Double((x - rect.minX) / rect.width) * (Self.hottest - Self.coolest)
        }

        func speed(atY y: CGFloat) -> Double {
            Double((rect.maxY - y) / rect.height) * 100
        }
    }
}
