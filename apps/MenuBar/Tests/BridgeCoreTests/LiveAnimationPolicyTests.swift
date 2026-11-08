import XCTest
@testable import BridgeCore

final class LiveAnimationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testArrivalPulseRequiresNewFreshEvidence() {
        XCTAssertTrue(shouldPulse(now))
        XCTAssertTrue(shouldPulse(now, after: now.addingTimeInterval(-1)))
        XCTAssertFalse(shouldPulse(now, after: now))
        XCTAssertFalse(shouldPulse(now.addingTimeInterval(-1), after: now))
        XCTAssertFalse(shouldPulse(now.addingTimeInterval(-LiveAnimationPolicy.freshnessWindow)))
        XCTAssertFalse(shouldPulse(now.addingTimeInterval(-300)), "Five-minute working state must not sustain motion")
        XCTAssertFalse(shouldPulse(now.addingTimeInterval(0.001)))
        XCTAssertFalse(shouldPulse(nil))
    }

    func testInvalidDatesAndClocksFailClosed() {
        for value in [Double.nan, .infinity, -.infinity] {
            let invalid = Date(timeIntervalSinceReferenceDate: value)
            XCTAssertNil(LiveAnimationPolicy.age(of: invalid, now: now))
            XCTAssertNil(LiveAnimationPolicy.age(of: now, now: invalid))
            XCTAssertNil(LiveAnimationPolicy.pulseDuration(evidenceAt: invalid, now: now))
            XCTAssertFalse(shouldPulse(invalid))
            XCTAssertFalse(shouldPulse(now, after: invalid))
        }
        XCTAssertEqual(LiveAnimationPolicy.age(of: now, now: now), 0)
        XCTAssertNil(LiveAnimationPolicy.age(of: now.addingTimeInterval(1), now: now))
    }

    func testVisibilityMotionAndWorkingGatesAreIndependent() {
        XCTAssertFalse(shouldPulse(now, visible: false))
        XCTAssertFalse(shouldPulse(now, reduceMotion: true))
        XCTAssertFalse(shouldPulse(now, working: false))
        XCTAssertTrue(shouldPulse(now, visible: true, reduceMotion: false))
    }

    func testPulseEndsAtTwoCyclesOrFreshnessWhicheverComesFirst() {
        XCTAssertEqual(LiveAnimationPolicy.pulseDuration(evidenceAt: now, now: now), 4.8)
        XCTAssertEqual(LiveAnimationPolicy.pulseDuration(evidenceAt: now, now: now, fast: true), 2.6)
        XCTAssertEqual(LiveAnimationPolicy.pulseDuration(evidenceAt: now.addingTimeInterval(-14), now: now), 1)
        XCTAssertNil(LiveAnimationPolicy.pulseDuration(evidenceAt: now.addingTimeInterval(-15), now: now))
        XCTAssertNil(LiveAnimationPolicy.pulseDuration(evidenceAt: now, now: now.addingTimeInterval(15)))
    }

    func testInvalidOrFutureSiblingCannotMaskNewestUsableEvidence() {
        let older = now.addingTimeInterval(-1)
        let invalid = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertEqual(LiveAnimationPolicy.newestEvidence([nil, older, now, now, invalid, now.addingTimeInterval(1)], now: now), now)
        XCTAssertNil(LiveAnimationPolicy.newestEvidence([nil, invalid, now.addingTimeInterval(1)], now: now))
    }

    private func shouldPulse(_ evidenceAt: Date?, after previous: Date? = nil, working: Bool = true,
                             visible: Bool = true, reduceMotion: Bool = false) -> Bool {
        LiveAnimationPolicy.shouldPulse(evidenceAt: evidenceAt, after: previous, now: now,
                                        working: working, visible: visible, reduceMotion: reduceMotion)
    }
}
