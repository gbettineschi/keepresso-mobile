import Foundation
public enum ObserverScratch {
    private static let prefix="keespresso-observer-"
    public static func create()throws->URL{
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(prefix+UUID().uuidString.lowercased(),isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return url
    }
    public static func validate(_ path:String)throws->URL{
        let url=URL(fileURLWithPath:path).standardizedFileURL
        let root=FileManager.default.temporaryDirectory.standardizedFileURL
        guard url.deletingLastPathComponent().path==root.path,url.lastPathComponent.hasPrefix(prefix),WireCrypto.validID(String(url.lastPathComponent.dropFirst(prefix.count))) else{throw CompanionError.invalid}
        let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard values.isDirectory==true,values.isSymbolicLink != true else{throw CompanionError.invalid};return url
    }
    public static func withDirectory<T>(_ operation:(URL)async throws->T)async throws->T{
        let url=try create();defer{try? FileManager.default.removeItem(at:url)};return try await operation(url)
    }
}
