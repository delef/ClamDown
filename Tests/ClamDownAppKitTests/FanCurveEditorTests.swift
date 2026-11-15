import Testing
@testable import ClamDownAppKit
import ClamDownShared

@Suite struct FanCurveEditorTests {
    private func point(_ temperature: Int, _ speed: Int) -> FanPoint { FanPoint(temperature: temperature, speed: speed) }

    @Test func advancedFromStandardLine() {
        #expect(FanCurveEditor.advanced(fromStart: 50, full: 75) == [point(50, 0), point(56, 25), point(63, 50), point(69, 75), point(75, 100)])
        #expect(FanCurveEditor.defaultAdvanced == FanCurveEditor.advanced(fromStart: 40, full: 70))
    }

    @Test func advancedFromEdgeStandardStaysOnOrAboveFloor() {
        for (start, full) in [(70, 95), (69, 95)] {
            let points = FanCurveEditor.advanced(fromStart: start, full: full)
            #expect(points.count == 5)
            for point in points {
                #expect(Double(point.speed) >= SafetyFloor.speed(at: Double(point.temperature)), "\(start)/\(full): \(point)")
            }
            #expect(zip(points, points.dropFirst()).allSatisfy { $0.temperature <= $1.temperature && $0.speed <= $1.speed })
        }
        #expect(FanCurveEditor.advanced(fromStart: 70, full: 95) == [point(70, 0), point(76, 25), point(83, 52), point(89, 76), point(95, 100)])
    }

    @Test func standardStopsAtGap() {
        #expect(FanCurveEditor.movedStandard(start: 50, full: 75, dragging: 0, to: 74) == (70, 75))
        #expect(FanCurveEditor.movedStandard(start: 50, full: 75, dragging: 1, to: 52) == (50, 55))
        // The gap stops the start point before the range does, and the other point never moves.
        #expect(FanCurveEditor.movedStandard(start: 50, full: 60, dragging: 0, to: 70) == (55, 60))
    }

    @Test func standardStaysInItsRanges() {
        #expect(FanCurveEditor.movedStandard(start: 50, full: 75, dragging: 0, to: 20) == (40, 75))
        #expect(FanCurveEditor.movedStandard(start: 50, full: 75, dragging: 1, to: 100) == (50, 95))
    }

    @Test func advancedStopsAtNeighbours() {
        let points = FanCurveEditor.advanced(fromStart: 50, full: 75)  // 50/0, 56/25, 63/50, 69/75, 75/100
        // First point: past the next one, right and up.
        #expect(FanCurveEditor.movedAdvanced(points, dragging: 0, to: point(60, 40))[0] == point(56, 25))
        // Middle point: past the next one, then past the previous one.
        #expect(FanCurveEditor.movedAdvanced(points, dragging: 2, to: point(80, 90))[2] == point(69, 75))
        #expect(FanCurveEditor.movedAdvanced(points, dragging: 2, to: point(50, 10))[2] == point(56, 25))
        // Last point: past the previous one, left and down.
        #expect(FanCurveEditor.movedAdvanced(points, dragging: 4, to: point(60, 20))[4] == point(69, 75))
        // Neighbours stay where they are: a point stops, it does not push.
        let moved = FanCurveEditor.movedAdvanced(points, dragging: 2, to: point(80, 90))
        #expect(moved[1] == points[1] && moved[3] == points[3])
    }

    @Test func advancedStaysInRange() {
        let points = FanCurveEditor.defaultAdvanced
        #expect(FanCurveEditor.movedAdvanced(points, dragging: 0, to: point(30, -10))[0] == point(40, 0))
        #expect(FanCurveEditor.movedAdvanced(points, dragging: 4, to: point(120, 130))[4] == point(100, 100))
    }

    @Test func advancedCannotEnterFloor() {
        let points = [point(40, 0), point(50, 10), point(60, 20), point(80, 60), point(100, 100)]
        let middle = FanCurveEditor.movedAdvanced(points, dragging: 2, to: point(90, 10))[2]
        #expect(middle == point(80, 40))
        #expect(Double(middle.speed) == SafetyFloor.speed(at: Double(middle.temperature)))
        // Straight down into the floor: the speed stops at the floor.
        #expect(FanCurveEditor.movedAdvanced(points, dragging: 3, to: point(80, 10))[3] == point(80, 40))
        // The last point at the right edge must run at full speed.
        #expect(FanCurveEditor.movedAdvanced(points, dragging: 4, to: point(100, 50))[4] == point(100, 100))
        // A next point slow for its place stops the dragged one where the floor reaches that speed.
        let slowNext = [point(40, 0), point(50, 10), point(60, 20), point(100, 60), point(100, 100)]
        let limited = FanCurveEditor.movedAdvanced(slowNext, dragging: 2, to: point(90, 10))[2]
        #expect(limited == point(85, 60))
        #expect(SafetyFloor.speed(at: Double(limited.temperature)) <= 60)
    }

    @Test func firstAdvancedCopiesStandardThenKeepsOwn() {
        var s = Settings()
        s.fanStartTemperature = 60
        s.fanFullSpeedTemperature = 80
        s = FanCurveEditor.chooseAdvanced(s)
        #expect(s.fanCurveMode == .advanced)
        #expect(s.fanAdvancedPoints == [point(60, 0), point(65, 25), point(70, 50), point(75, 75), point(80, 100)])
        let edited = FanCurveEditor.movedAdvanced(s.fanAdvancedPoints!, dragging: 1, to: point(62, 40))
        s.fanAdvancedPoints = edited
        s.fanCurveMode = .standard
        #expect(s.fanStartTemperature == 60 && s.fanFullSpeedTemperature == 80)
        s.fanStartTemperature = 45
        s = FanCurveEditor.chooseAdvanced(s)
        #expect(s.fanCurveMode == .advanced && s.fanAdvancedPoints == edited)
    }

    @Test func resetOnlyTouchesTheVisibleMode() {
        var s = Settings()
        s.fanStartTemperature = 60
        s.fanFullSpeedTemperature = 80
        let own = FanCurveEditor.movedAdvanced(FanCurveEditor.defaultAdvanced, dragging: 4, to: point(90, 100))
        s.fanAdvancedPoints = own

        let standard = FanCurveEditor.reset(s)
        #expect(standard.fanStartTemperature == 40 && standard.fanFullSpeedTemperature == 70)
        #expect(standard.fanAdvancedPoints == own && standard.fanCurveMode == .standard)

        s.fanCurveMode = .advanced
        let advanced = FanCurveEditor.reset(s)
        #expect(advanced.fanAdvancedPoints == FanCurveEditor.defaultAdvanced)
        #expect(advanced.fanStartTemperature == 60 && advanced.fanFullSpeedTemperature == 80 && advanced.fanCurveMode == .advanced)
    }

    // MARK: - Moves from the chart

    @Test func chartMovesStandardSidewaysOnly() {
        let line = StandardCurve.points(start: 50, full: 75)
        #expect(FanCurveEditor.moved(line, mode: .standard, dragging: 0, to: point(58, 80)) == [point(58, 0), point(75, 100)])
        #expect(FanCurveEditor.moved(line, mode: .standard, dragging: 1, to: point(99, 3)) == [point(50, 0), point(95, 100)])
        #expect(FanCurveEditor.moved(line, mode: .standard, dragging: 0, to: point(90, 0)) == [point(70, 0), point(75, 100)])
    }

    @Test func chartMovesAdvancedByItsRules() {
        let points = FanCurveEditor.defaultAdvanced
        #expect(FanCurveEditor.moved(points, mode: .advanced, dragging: 2, to: point(60, 40))
            == FanCurveEditor.movedAdvanced(points, dragging: 2, to: point(60, 40)))
    }

    @Test func chartIgnoresAPointThatDoesNotExist() {
        let line = StandardCurve.points(start: 50, full: 75)
        #expect(FanCurveEditor.moved(line, mode: .standard, dragging: 2, to: point(60, 0)) == line)
        #expect(FanCurveEditor.moved(FanCurveEditor.defaultAdvanced, mode: .advanced, dragging: 5, to: point(60, 0))
            == FanCurveEditor.defaultAdvanced)
    }

    @Test func chartMoveChangesOnlyTheVisibleModeInTheSettings() {
        var s = Settings()
        let moved = FanCurveEditor.moved(s, dragging: 1, to: point(80, 10))
        #expect(moved.fanStartTemperature == 40 && moved.fanFullSpeedTemperature == 80)
        #expect(moved.fanAdvancedPoints == nil)

        s = FanCurveEditor.chooseAdvanced(s)
        let advanced = FanCurveEditor.moved(s, dragging: 4, to: point(90, 100))
        #expect(advanced.fanAdvancedPoints?[4] == point(90, 100))
        #expect(advanced.fanStartTemperature == 40 && advanced.fanFullSpeedTemperature == 70)
    }

    @Test func chartShowsTheVisibleCurveEvenWithFanControlOff() {
        var s = Settings()
        s.fanControlEnabled = false
        #expect(s.fanCurvePoints == StandardCurve.points(start: 40, full: 70))
        #expect(s.fanPolicy.isOff)
        s.fanCurveMode = .advanced
        #expect(s.fanCurvePoints == FanCurveEditor.defaultAdvanced)
    }
}
