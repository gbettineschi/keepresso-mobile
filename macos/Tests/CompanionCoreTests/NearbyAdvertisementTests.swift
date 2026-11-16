import CoreBluetooth
import Testing
@testable import CompanionCore

struct NearbyAdvertisementTests {
    @Test func routingServiceFitsThePrimaryAdvertisementWithoutOverflow(){
        let service=CBUUID(string:"73f8d1c0-823f-4c2f-9e0a-4454129f3001")
        let data=NearbyAdvertisement.data(service:service)
        let services=data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name=data[CBAdvertisementDataLocalNameKey] as? String ?? ""
        #expect(services.contains(service))
        // Apple's primary advertisement allowance is 28 value bytes. Keep the
        // route discoverable without relying on its Apple-only overflow area.
        let valueBytes=services.reduce(0){$0+$1.data.count}+name.utf8.count
        #expect(valueBytes<=28)
    }
}
