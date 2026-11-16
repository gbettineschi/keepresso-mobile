import Foundation

/// Public client options only. Sender credentials are never part of this model.
public struct FirebaseClientConfiguration: Codable, Equatable, Sendable {
    public let projectId: String
    public let applicationId: String
    public let apiKey: String
    public let senderId: String

    static func validProject(_ value: String) -> Bool {
        value.range(of: "^[a-z][a-z0-9-]{4,28}[a-z0-9]$", options: .regularExpression) != nil
    }
    public init(projectId: String, applicationId: String, apiKey: String, senderId: String) throws {
        let parts = applicationId.split(separator: ":", omittingEmptySubsequences: false)
        guard Self.validProject(projectId), (1...32).contains(senderId.utf8.count), senderId.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              parts.count == 4, parts[0] == "1", parts[1] == Substring(senderId), parts[2] == "android",
              (1...128).contains(parts[3].count), parts[3].allSatisfy({ $0.isASCII && $0.isHexDigit }),
              (1...256).contains(apiKey.utf8.count), apiKey.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw CompanionError.invalid }
        self.projectId = projectId; self.applicationId = applicationId; self.apiKey = apiKey; self.senderId = senderId
    }
    enum CodingKeys: String, CodingKey { case projectId, applicationId, apiKey, senderId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(projectId:c.decode(String.self,forKey:.projectId),applicationId:c.decode(String.self,forKey:.applicationId),apiKey:c.decode(String.self,forKey:.apiKey),senderId:c.decode(String.self,forKey:.senderId))
    }
}

/// Learned only inside an already authenticated application session.
public struct InternetConfiguration: Codable, Equatable, Sendable {
    public let type: String
    public let version: Int
    public let endpointId: String
    public let firebase: FirebaseClientConfiguration?
    public init(endpointId: String, firebase: FirebaseClientConfiguration? = nil) throws {
        _ = try WireCrypto.bytes32(endpointId)
        type = "internet_config"; version = 1; self.endpointId = endpointId; self.firebase = firebase
    }
    enum CodingKeys: String, CodingKey { case type, version, endpointId, firebase }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self,forKey:.type) == "internet_config", try c.decode(Int.self,forKey:.version) == 1 else { throw CompanionError.invalid }
        try self.init(endpointId:c.decode(String.self,forKey:.endpointId),firebase:c.decodeIfPresent(FirebaseClientConfiguration.self,forKey:.firebase))
    }
    public func encoded() throws -> Data { try WireJSON.encoder.encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw CompanionError.limit }
        return try WireJSON.decoder.decode(Self.self,from:data)
    }
}
