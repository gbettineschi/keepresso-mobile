import CoreBluetooth

public enum NearbyAdvertisement {
    public static func data(service:CBUUID)->[String:Any]{
        // Keep the 128-bit route in the normal advertisement. The optional
        // product name competes for space and is not used for authentication.
        [CBAdvertisementDataServiceUUIDsKey:[service]]
    }
}
