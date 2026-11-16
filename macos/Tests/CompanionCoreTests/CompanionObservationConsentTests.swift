import Foundation
import Testing
import CompanionCore

struct CompanionObservationConsentTests {
    @Test func envelopeRoundTripsOpaqueSeparateGrants() throws {
        let encoded = try #require(CompanionObservationConsent.encode(folders: Data([1, 2]), steam: Data([3])))
        let decoded = try #require(CompanionObservationConsent.decode(encoded))
        #expect(decoded.folders == Data([1, 2]))
        #expect(decoded.steam == Data([3]))
    }
    @Test func missingMalformedVersionAndTotalOversizeDeny() {
        for data in [nil, Data(), Data("{}".utf8), Data(#"{"version":2}"#.utf8), Data(repeating: 0, count: 32_769)] as [Data?] {
            #expect(CompanionObservationConsent.decode(data) == nil)
        }
        #expect(CompanionObservationConsent.encode(folders: Data(repeating: 1, count: 25_000), steam: Data(repeating: 2, count: 100)) == nil)
        #expect(CompanionObservationConsent.encode(folders: nil, steam: nil) != nil)
    }
}
