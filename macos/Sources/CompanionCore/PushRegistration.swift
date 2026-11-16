import Foundation
import CryptoKit

public struct PushRegistration: Codable, Equatable, Sendable {
    public let type: String
    public let projectId: String
    public let token: String
    public let revision: Int64
    public var tokenHash: String { Data(SHA256.hash(data:Data(token.utf8))).base64EncodedString() }
    public init(projectId: String, token: String, revision: Int64) throws {
        guard FirebaseClientConfiguration.validProject(projectId), revision > 0,
              (1...4096).contains(token.utf8.count), token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw CompanionError.invalid }
        type = "push_registration"; self.projectId = projectId; self.token = token; self.revision = revision
    }
    enum CodingKeys: String, CodingKey { case type, projectId, token, revision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self,forKey:.type) == "push_registration" else { throw CompanionError.invalid }
        try self.init(projectId:c.decode(String.self,forKey:.projectId),token:c.decode(String.self,forKey:.token),revision:c.decode(Int64.self,forKey:.revision))
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8192 else { throw CompanionError.limit }
        return try WireJSON.decoder.decode(Self.self,from:data)
    }
    public func encoded() throws -> Data { try WireJSON.encoder.encode(self) }
}

public struct PushRegistrationAck: Codable, Equatable, Sendable {
    public let type: String
    public let projectId: String
    public let revision: Int64
    public let tokenHash: String
    public init(projectId: String, revision: Int64, tokenHash: String) throws {
        guard FirebaseClientConfiguration.validProject(projectId), revision > 0 else { throw CompanionError.invalid }
        _ = try WireCrypto.bytes32(tokenHash)
        type = "push_registered"; self.projectId = projectId; self.revision = revision; self.tokenHash = tokenHash
    }
    public func matches(_ value: PushRegistration) -> Bool { projectId == value.projectId && revision == value.revision && tokenHash == value.tokenHash }
    enum CodingKeys: String, CodingKey { case type, projectId, revision, tokenHash }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self,forKey:.type) == "push_registered" else { throw CompanionError.invalid }
        try self.init(projectId:c.decode(String.self,forKey:.projectId),revision:c.decode(Int64.self,forKey:.revision),tokenHash:c.decode(String.self,forKey:.tokenHash))
    }
}

/// Pure monotonic transition; callers persist successfully before returning the acknowledgement.
public struct PushTokenRegistry: Codable, Sendable {
    private var records: [String:PushRegistration] = [:]
    public init() {}
    public func registration(deviceId: String) -> PushRegistration? { records[deviceId] }
    public mutating func register(deviceId: String, registration: PushRegistration) throws -> PushRegistrationAck {
        guard WireCrypto.validID(deviceId) else { throw CompanionError.invalid }
        if let previous = records[deviceId] {
            guard registration.revision >= previous.revision,
                  registration.revision != previous.revision || registration == previous else { throw CompanionError.mismatch }
        } else { guard records.count < 8 else { throw CompanionError.limit } }
        records[deviceId] = registration
        return try PushRegistrationAck(projectId:registration.projectId,revision:registration.revision,tokenHash:registration.tokenHash)
    }
    public mutating func remove(deviceId: String) { records.removeValue(forKey:deviceId) }
    enum CodingKeys: String, CodingKey { case records }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        let decoded = try c.decode([String:PushRegistration].self,forKey:.records)
        guard decoded.count <= 8, decoded.keys.allSatisfy(WireCrypto.validID) else { throw CompanionError.invalid }
        records = decoded
    }
}
