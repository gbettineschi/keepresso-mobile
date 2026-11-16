import Foundation

/// One bounded, versioned payload for the existing private scratch transport.
/// The contained grants stay opaque here; each observer validates its own scope.
public struct CompanionObservationConsent {
    public static let maximumBytes = 32_768
    public let folders: Data?
    public let steam: Data?

    private struct Envelope: Codable {
        let type: String
        let version: Int
        let folders: Data?
        let steam: Data?
    }
    public static func encode(folders: Data?, steam: Data?) -> Data? {
        guard (folders?.count ?? 0) <= maximumBytes, (steam?.count ?? 0) <= maximumBytes,
              let data = try? JSONEncoder().encode(Envelope(type: "companion-observation-consent", version: 1, folders: folders, steam: steam)),
              data.count <= maximumBytes else { return nil }
        return data
    }
    public static func decode(_ data: Data?) -> CompanionObservationConsent? {
        guard let data, data.count <= maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.type == "companion-observation-consent", envelope.version == 1 else { return nil }
        return Self(folders: envelope.folders, steam: envelope.steam)
    }
}
