import Foundation
import XCTest
@testable import MightySPulse

final class TestModeTests: XCTestCase {
    private func sentDebug(_ options: PulseOptions) -> Bool? {
        let h = Harness(options: options)
        h.send("mode.check")
        return h.events.first?["debug"] as? Bool
    }
    func testExplicitValueWinsInBothDirections() {
        var on = PulseOptions(); on.debug = true
        var off = PulseOptions(); off.debug = false
        XCTAssertEqual(sentDebug(on), true)
        XCTAssertEqual(sentDebug(off), false)
    }
    func testDefaultFollowsTheBuildConfigurationAndIsStable() {
        #if DEBUG
        XCTAssertTrue(PulseOptions().debug)
        #else
        XCTAssertFalse(PulseOptions().debug)
        #endif
        XCTAssertEqual(PulseOptions().debug, PulseOptions().debug)
    }
    func testDefaultReachesTheWireWhenNoOptionIsGiven() {
        XCTAssertEqual(sentDebug(PulseOptions()), PulseOptions().debug)
    }
}
