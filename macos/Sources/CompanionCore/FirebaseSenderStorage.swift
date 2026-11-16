import Foundation

public struct FirebaseSenderStorage {
    private let file:PrivateStateFile
    public init(url:URL){file=PrivateStateFile(url:url)}
    public func load()throws->FirebaseSenderConfiguration? {
        guard let data=try file.read() else{return nil}
        return try JSONDecoder().decode(FirebaseSenderConfiguration.self,from:data)
    }
    public func save(_ configuration:FirebaseSenderConfiguration)throws {
        _=try load()
        try file.write(JSONEncoder().encode(configuration))
    }
}

@MainActor public final class PushTokenStorage {
    private let file:PrivateStateFile
    private var registry:PushTokenRegistry
    public init(url:URL)throws {
        file=PrivateStateFile(url:url)
        if let data=try file.read(){registry=try JSONDecoder().decode(PushTokenRegistry.self,from:data)}else{registry=PushTokenRegistry()}
    }
    public func registration(_ device:String)->PushRegistration?{registry.registration(deviceId:device)}
    public func register(_ registration:PushRegistration,device:String)throws->PushRegistrationAck {
        var updated=registry;let ack=try updated.register(deviceId:device,registration:registration)
        try file.write(JSONEncoder().encode(updated));registry=updated;return ack
    }
    public func remove(_ device:String)throws {
        var updated=registry;updated.remove(deviceId:device)
        try file.write(JSONEncoder().encode(updated));registry=updated
    }
}
