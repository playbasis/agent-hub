import Foundation
import XCTest
@testable import ClaudeCodexBridgeMenuBar

/// The animation is decorative: its clock must be bounded, deterministic and
/// disabled when it cannot provide visible feedback. None of these tests opens
/// a provider connection or changes a system accessibility preference.
final class HydrationLoadingTests: XCTestCase {
    @MainActor func testDiagnosticReopenDoesNotSpawnAnEmptyWorkspace() {
        var opened = 0
        let delegate = AppLifecycleDelegate(showWorkspace: { opened += 1 }, restoresWorkspace: false)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        XCTAssertEqual(opened, 0)
    }

    func testElapsedIsDisabledForStaticStatesAndRejectsInvalidDates() {
        let start = Date(timeIntervalSince1970: 1_793_750_400)
        XCTAssertEqual(Hydration.elapsed(start.addingTimeInterval(0.25), since: start, animated: true), 0.25)
        XCTAssertEqual(Hydration.elapsed(start.addingTimeInterval(-10), since: start, animated: true), 0)
        XCTAssertNil(Hydration.elapsed(start.addingTimeInterval(10), since: start, animated: false))
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(Hydration.elapsed(Date(timeIntervalSince1970: invalid), since: start, animated: true))
            XCTAssertNil(Hydration.elapsed(start, since: Date(timeIntervalSince1970: invalid), animated: true))
        }
    }

    func testClockRequiresVisibleMountedMotionAllowedNonSnapshotContent() {
        for appeared in [false, true] {
            for visible in [false, true] {
                for reduceMotion in [false, true] {
                    for snapshot in [false, true] {
                        XCTAssertEqual(Hydration.shouldAnimate(appeared: appeared, windowVisible: visible,
                                                               reduceMotion: reduceMotion, snapshot: snapshot),
                                       appeared && visible && !reduceMotion && !snapshot)
                    }
                }
            }
        }
        XCTAssertEqual(Hydration.frameInterval, 1.0 / 30, accuracy: 0.000_001)
    }

    func testEntranceStaggersAndRemainsMonotonicWithinItsLayoutBounds() {
        for order in 0 ..< 8 {
            let begin = Double(order) * Hydration.stagger
            XCTAssertEqual(Hydration.entrance(order: order, t: begin), 0, accuracy: 0.000_001)
            XCTAssertEqual(Hydration.entrance(order: order, t: begin + Hydration.entrance), 1, accuracy: 0.000_001)
            var previous = 0.0
            for tick in 0 ... 100 {
                let value = Hydration.entrance(order: order, t: begin + Double(tick) * Hydration.entrance / 100)
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, previous)
                XCTAssertTrue((0 ... 1).contains(value))
                previous = value
            }
        }
        XCTAssertGreaterThan(Hydration.entrance(order: 0, t: 0.1), Hydration.entrance(order: 1, t: 0.1))
        XCTAssertEqual(Hydration.entrance(order: -1, t: 0.1), Hydration.entrance(order: 0, t: 0.1))
        XCTAssertEqual(Hydration.entrance(order: 0, t: -1), 0)
    }

    func testStaticAndInvalidEntranceTimesShowSettledTiles() {
        XCTAssertEqual(Hydration.entrance(order: 7, t: nil), 1)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(Hydration.entrance(order: 7, t: invalid), 1)
        }
        XCTAssertEqual(Hydration.entrance(order: 0, t: Double.greatestFiniteMagnitude), 1)
    }

    func testSweepHasAnEntranceDelayAnOrderedPassAndARealRest() throws {
        let order = 3
        let begin = Hydration.entrance + Double(order) * Hydration.sweepLag
        XCTAssertNil(Hydration.sweep(order: order, t: begin - 0.001, lag: Hydration.sweepLag))
        XCTAssertEqual(try XCTUnwrap(Hydration.sweep(order: order, t: begin, lag: Hydration.sweepLag)), 0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(Hydration.sweep(order: order, t: begin + Hydration.sweepTravel / 2, lag: Hydration.sweepLag)), 0.5, accuracy: 0.000_001)
        XCTAssertNil(Hydration.sweep(order: order, t: begin + Hydration.sweepTravel + 0.001, lag: Hydration.sweepLag))
        XCTAssertNil(Hydration.sweep(order: order, t: begin + Hydration.sweepPeriod - 0.001, lag: Hydration.sweepLag))
        XCTAssertGreaterThan(Hydration.sweepPeriod, Hydration.sweepTravel)
    }

    func testSweepRepeatsWithoutInventingFramesForReducedMotionOrBadInputs() throws {
        let at = Hydration.entrance + 0.37
        let first = try XCTUnwrap(Hydration.sweep(order: 0, t: at, lag: 0))
        for cycle in 1 ... 10 {
            XCTAssertEqual(try XCTUnwrap(Hydration.sweep(order: 0, t: at + Double(cycle) * Hydration.sweepPeriod, lag: 0)),
                           first, accuracy: 0.000_001)
        }
        XCTAssertNil(Hydration.sweep(order: 0, t: nil, lag: 0))
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(Hydration.sweep(order: 0, t: invalid, lag: 0))
            XCTAssertNil(Hydration.sweep(order: 0, t: at, lag: invalid))
        }
        XCTAssertNil(Hydration.sweep(order: 0, t: at, lag: -0.1))
        XCTAssertNil(Hydration.sweep(order: 0, t: -1, lag: 0))
        XCTAssertEqual(Hydration.sweep(order: -4, t: at, lag: 0.12), Hydration.sweep(order: 0, t: at, lag: 0.12))
    }

    func testEveryReturnedSweepProgressIsFiniteAndInsideItsTile() {
        for order in 0 ..< 8 {
            for tick in 0 ... 1_000 {
                if let phase = Hydration.sweep(order: order, t: Double(tick) / 60, lag: Hydration.sweepLag) {
                    XCTAssertTrue(phase.isFinite)
                    XCTAssertTrue((0 ..< 1).contains(phase))
                }
            }
        }
    }

    func testGlyphUsesPositiveModuloAtItsFirstFrames() {
        for y in 0 ..< 3 {
            for x in 0 ..< 3 {
                for time in [-10.0, -0.001, 0, 0.001, 0.01, 0.1, 0.2, 0.8, 1, 10, 1_000] {
                    let level = Hydration.glyphLevel(x: x, y: y, t: time)
                    XCTAssertTrue(level.isFinite)
                    XCTAssertGreaterThanOrEqual(level, 0, "A negative remainder must never create negative opacity")
                    XCTAssertLessThanOrEqual(level, 1)
                }
            }
        }
    }

    func testStaticGlyphHasAStableDiagonalAndInvalidTimesStayStatic() {
        XCTAssertEqual(Hydration.glyphLevel(x: 0, y: 0, t: nil), 1)
        XCTAssertEqual(Hydration.glyphLevel(x: 2, y: 2, t: nil), 0.2, accuracy: 0.000_001)
        for y in 0 ..< 3 {
            for x in 0 ..< 3 {
                let settled = Hydration.glyphLevel(x: x, y: y, t: nil)
                for invalid in [Double.nan, .infinity, -.infinity] {
                    XCTAssertEqual(Hydration.glyphLevel(x: x, y: y, t: invalid), settled)
                }
            }
        }
    }

    func testNoiseIsStableBoundedAndNotOneSharedBrightness() {
        var values: Set<Double> = []
        for salt in [-1, 0, 1, 7, Int.max] {
            for y in 0 ..< 12 {
                for x in 0 ..< 24 {
                    let value = Hydration.noise(x, y, salt)
                    XCTAssertEqual(value, Hydration.noise(x, y, salt))
                    XCTAssertTrue((0 ..< 1).contains(value))
                    values.insert(value)
                }
            }
        }
        XCTAssertGreaterThan(values.count, 100)
    }

    func testPreviewRequiresExplicitDiagnosticGateAndSupportedSurface() throws {
        XCTAssertNil(HydrationPreview.Configuration.read([:]))
        XCTAssertNil(HydrationPreview.Configuration.read(["BRIDGE_HYDRATION_PREVIEW": "overview"]))
        XCTAssertNil(HydrationPreview.Configuration.read(["BRIDGE_UI_PREVIEW": "true", "BRIDGE_HYDRATION_PREVIEW": "overview"]))
        XCTAssertNil(HydrationPreview.Configuration.read(["BRIDGE_UI_PREVIEW": "1", "BRIDGE_HYDRATION_PREVIEW": "unknown"]))
        for surface in ["overview", "now", "projects", "panel"] {
            let config = try XCTUnwrap(HydrationPreview.Configuration.read(["BRIDGE_UI_PREVIEW": "1", "BRIDGE_HYDRATION_PREVIEW": surface]))
            XCTAssertEqual(config.surface, surface)
            XCTAssertEqual(config.width, surface == "panel" ? 350 : 1_000)
            XCTAssertNil(config.frozenTime)
            XCTAssertNil(config.reduceMotion, "A preview without an override inherits the OS accessibility setting")
            XCTAssertFalse(config.increasedContrast)
            XCTAssertFalse(config.light)
        }
    }

    func testPreviewBoundsTimeAndWidthInsteadOfPassingInvalidGeometry() throws {
        let base = ["BRIDGE_UI_PREVIEW": "1", "BRIDGE_HYDRATION_PREVIEW": "panel"]
        for value in ["nan", "inf", "-inf", "-1", "61", "not-a-number"] {
            var environment = base; environment["BRIDGE_HYDRATION_TIME"] = value
            XCTAssertNil(try XCTUnwrap(HydrationPreview.Configuration.read(environment)).frozenTime)
        }
        for value in ["0", "0.25", "60"] {
            var environment = base; environment["BRIDGE_HYDRATION_TIME"] = value
            XCTAssertEqual(try XCTUnwrap(HydrationPreview.Configuration.read(environment)).frozenTime, Double(value))
        }
        for value in ["nan", "inf", "-inf", "-1", "0", "319", "1601", "not-a-number"] {
            var environment = base; environment["BRIDGE_HYDRATION_WIDTH"] = value
            XCTAssertEqual(try XCTUnwrap(HydrationPreview.Configuration.read(environment)).width, 350)
        }
        for value in ["320", "350.5", "1600"] {
            var environment = base; environment["BRIDGE_HYDRATION_WIDTH"] = value
            XCTAssertEqual(try XCTUnwrap(HydrationPreview.Configuration.read(environment)).width, try XCTUnwrap(Double(value)))
        }
    }

    func testPreviewAccessibilityOverridesAreExplicitAndDoNotChangeSystemSettings() throws {
        let base = ["BRIDGE_UI_PREVIEW": "1", "BRIDGE_HYDRATION_PREVIEW": "overview"]
        for (raw, expected) in [("1", true), ("0", false)] {
            var environment = base
            environment["BRIDGE_HYDRATION_REDUCE_MOTION"] = raw
            XCTAssertEqual(try XCTUnwrap(HydrationPreview.Configuration.read(environment)).reduceMotion, expected)
        }
        var invalid = base; invalid["BRIDGE_HYDRATION_REDUCE_MOTION"] = "true"
        XCTAssertNil(try XCTUnwrap(HydrationPreview.Configuration.read(invalid)).reduceMotion)
        var styled = base
        styled["BRIDGE_HYDRATION_CONTRAST"] = "1"
        styled["BRIDGE_HYDRATION_LIGHT"] = "1"
        let config = try XCTUnwrap(HydrationPreview.Configuration.read(styled))
        XCTAssertTrue(config.increasedContrast)
        XCTAssertTrue(config.light)
    }
}
