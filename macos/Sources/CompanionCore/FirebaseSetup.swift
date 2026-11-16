import Foundation
import CryptoKit

public enum FirebaseSetup {
    /// nil means the owner cancelled either file picker. No partial import exists.
    public static func importFiles(service:Data?,client:Data?)throws->FirebaseSenderConfiguration? {
        guard let service,let client else{return nil}
        guard client.count<=65_536 else{throw CompanionError.limit}
        let json=try WireJSON.object(client)
        guard let project=json["project_info"] as? [String:Any],let projectId=project["project_id"] as? String,
              let sender=project["project_number"] as? String,let clients=json["client"] as? [[String:Any]] else{throw CompanionError.invalid}
        let matching=clients.filter{(($0["client_info"] as? [String:Any])?["android_client_info"] as? [String:Any])?["package_name"] as? String == "io.github.gbettineschi.keepressomobile"}
        guard matching.count==1,let entry=matching.first,let info=entry["client_info"] as? [String:Any],let application=info["mobilesdk_app_id"] as? String,
              let keys=entry["api_key"] as? [[String:Any]],let apiKey=keys.first?["current_key"] as? String else{throw CompanionError.invalid}
        let options=try FirebaseClientConfiguration(projectId:projectId,applicationId:application,apiKey:apiKey,senderId:sender)
        return try FirebaseSenderConfiguration.importServiceAccount(service,client:options)
    }
}

/// A successful application authentication over iroh ends legacy bootstrap for
/// that exact device key. No server account or phone pairing is removed here.
@MainActor public final class InternetMigration {
    private let file:PrivateStateFile
    private var learned:[String:String]
    public init(url:URL)throws {
        file=PrivateStateFile(url:url)
        learned=try file.read().map{try JSONDecoder().decode([String:String].self,from:$0)} ?? [:]
        guard learned.count<=32,learned.keys.allSatisfy(WireCrypto.validID) else{throw CompanionError.invalid}
        for value in learned.values{_=try WireCrypto.bytes32(value)}
    }
    private func hash(_ device:AuthorizedDevice)->String{Data(SHA256.hash(data:device.key)).base64EncodedString()}
    public func needsLegacy(_ devices:[AuthorizedDevice])->Bool{devices.contains{learned[$0.deviceId] != hash($0)}}
    public func authenticated(_ device:AuthorizedDevice)throws {
        guard WireCrypto.validID(device.deviceId),device.key.count==32 else{throw CompanionError.invalid}
        if learned[device.deviceId]==hash(device){return}
        var next=learned;next[device.deviceId]=hash(device)
        guard next.count<=32 else{throw CompanionError.limit}
        try file.write(JSONEncoder().encode(next));learned=next
    }
}
