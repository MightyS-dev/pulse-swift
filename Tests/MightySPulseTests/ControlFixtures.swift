import Foundation
import XCTest
@testable import MightySPulse

/// The four shared tables, copied byte for byte from the server contract.
enum ControlFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/control-v1"))
        return try Data(contentsOf: url)
    }
    static func json(_ name: String) throws -> Any { try JSONSerialization.jsonObject(with: data(name)) }

    /// The `ControlInput` of one row of `decision-cases.json`.
    static func input(_ raw: [String: Any]) -> ControlInput {
        var input = ControlInput(now: ControlClock.parse(raw["now"] as! String)!)
        input.platform = raw["platform"] as! String
        input.appVersion = raw["appVersion"] as! String
        input.debug = raw["debug"] as! Bool
        input.sdk = raw["sdk"] as! String
        input.fromCache = raw["fromCache"] as! Bool
        input.cacheAgeHours = (raw["cacheAgeHours"] as! NSNumber).doubleValue
        input.updateReturns = (raw["updateReturns"] as! NSNumber).intValue
        input.playUpdateNotAvailable = raw["playUpdateNotAvailable"] as! Bool
        input.canBuildStoreLink = raw["canBuildStoreLink"] as! Bool
        input.suggestDismissedHoursAgo = (raw["suggestDismissedHoursAgo"] as? NSNumber)?.doubleValue
        input.shownAnnouncements = raw["shownAnnouncements"] as! [String]
        input.justUpdated = raw["justUpdated"] as! Bool
        input.whatsNewShown = raw["whatsNewShown"] as! Bool
        return input
    }
}
