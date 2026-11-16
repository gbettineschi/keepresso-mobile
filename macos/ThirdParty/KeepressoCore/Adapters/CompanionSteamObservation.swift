import Foundation
import CryptoKit
import Darwin

/// The seam is deliberately limited to bounded metadata and Steam bookkeeping.
/// Reading downloaded game contents is neither needed nor supported.
public struct CompanionSteamFileDriver: @unchecked Sendable {
    public struct Entry: Sendable {
        public enum Kind: Sendable { case regularFile, directory, symbolicLink, other }
        public let name: String
        public let kind: Kind
        public let modified: Date?
        public init(name: String, kind: Kind, modified: Date? = nil) {
            self.name = name; self.kind = kind; self.modified = modified
        }
    }
    public struct Listing: Sendable {
        public var entries: [Entry]
        public var complete: Bool
        public init(entries: [Entry], complete: Bool = true) { self.entries = entries; self.complete = complete }
    }
    public let defaultSteamapps: URL
    public let now: () -> Date
    public let readFile: (URL, Int) throws -> Data
    public let contents: (URL, Int) throws -> Listing
    public init(defaultSteamapps: URL, now: @escaping () -> Date = Date.init,
                readFile: @escaping (URL, Int) throws -> Data,
                contents: @escaping (URL, Int) throws -> Listing) {
        self.defaultSteamapps = defaultSteamapps; self.now = now
        self.readFile = readFile; self.contents = contents
    }
    /// Constructing this driver calculates paths only. No filesystem read occurs.
    public static var local: Self {
        local(defaultSteamapps: SteamDownload.defaultRoot().appendingPathComponent("steamapps", isDirectory: true))
    }
    /// An owned fixture root can exercise the production I/O without consulting
    /// an installed Steam library or the owner's home directory.
    public static func local(defaultSteamapps: URL) -> Self {
        Self(defaultSteamapps: defaultSteamapps, readFile: SteamMetadataIO.readFile, contents: SteamMetadataIO.contents)
    }
}

/// An explicit-check monitor with a truthful complete/partial result. The proof
/// is local setup evidence, not a claim that macOS permission cannot be revoked.
public final class CompanionSteamObservation: SteamDownloadMonitoring {
    private struct Proof: Codable {
        let type: String
        let version: Int
        let buildIdentity: String
        let base: String
        let roots: [String]
        let configurationSHA256: String
    }
    private struct Reading { var downloading = false; var complete = false }
    private static let maximumProofBytes = 24_000
    private static let maximumConfigurationBytes = 262_144
    private static let maximumManifestBytes = 65_536
    private static let maximumRoots = 32
    private static let maximumManifests = 2_048
    private static let maximumDirectoryEntries = 8_192
    private static let maximumWalkEntries = 16_384
    private static let maximumWalkDepth = 32
    private let identity: String
    private let consent: Data?
    private let driver: CompanionSteamFileDriver
    private let lock = NSLock()
    private var cached: Reading?

    public convenience init(buildIdentity: String, consentData: Data?) {
        self.init(buildIdentity: buildIdentity, consentData: consentData, driver: .local)
    }
    public init(buildIdentity: String, consentData: Data?, driver: CompanionSteamFileDriver) {
        identity = buildIdentity; consent = consentData; self.driver = driver
    }
    public var isDownloading: Bool { reading().downloading }
    public var hasCompleteReading: Bool { reading().complete }
    private func reading() -> Reading {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let result = observe(); cached = result; return result
    }
    public static func prepareConsent(buildIdentity: String, folderProbe: @escaping (URL) async -> Bool) async -> Data? {
        await prepareConsent(buildIdentity: buildIdentity, driver: .local, folderProbe: folderProbe)
    }
    public static func prepareConsent(buildIdentity: String, driver: CompanionSteamFileDriver,
                                      folderProbe: @escaping (URL) async -> Bool) async -> Data? {
        guard validIdentity(buildIdentity), let base = canonical(driver.defaultSteamapps),
              await folderProbe(URL(fileURLWithPath: base, isDirectory: true)) else { return nil }
        // Await local consent before touching even the fixed libraryfolders.vdf.
        // Blocking reads run independently of the caller's actor (including UI).
        let configuration = await Task.detached { () -> (Data, [String])? in
            guard let data = try? driver.readFile(configurationURL(base), maximumConfigurationBytes),
                  data.count <= maximumConfigurationBytes,
                  let roots = libraryRoots(data, base: base) else { return nil }
            return (data, roots)
        }.value
        guard !Task.isCancelled, let (data, roots) = configuration else { return nil }
        for root in roots where root != base {
            guard !Task.isCancelled, await folderProbe(URL(fileURLWithPath: root, isDirectory: true)) else { return nil }
        }
        guard !Task.isCancelled,
              let encoded = try? JSONEncoder().encode(Proof(type: "companion-steam-consent", version: 1,
                 buildIdentity: buildIdentity, base: base, roots: roots, configurationSHA256: fingerprint(data))),
              encoded.count <= maximumProofBytes else { return nil }
        return encoded
    }
    /// Metadata-only readiness; intentionally never opens Steam or a library.
    public static func isPrepared(_ data: Data?, buildIdentity: String) -> Bool {
        isPrepared(data, buildIdentity: buildIdentity, driver: .local)
    }
    public static func isPrepared(_ data: Data?, buildIdentity: String, driver: CompanionSteamFileDriver) -> Bool {
        guard let proof = decode(data, identity: buildIdentity) else { return false }
        return canonical(driver.defaultSteamapps) == proof.base
    }
    private static func decode(_ data: Data?, identity: String) -> Proof? {
        guard validIdentity(identity), let data, data.count <= maximumProofBytes,
              let proof = try? JSONDecoder().decode(Proof.self, from: data),
              proof.type == "companion-steam-consent", proof.version == 1, proof.buildIdentity == identity,
              canonical(URL(fileURLWithPath: proof.base)) == proof.base,
              !proof.roots.isEmpty, proof.roots.count <= maximumRoots,
              proof.roots == Array(Set(proof.roots)).sorted(), proof.roots.contains(proof.base),
              proof.roots.allSatisfy({ canonical(URL(fileURLWithPath: $0)) == $0 && URL(fileURLWithPath: $0).lastPathComponent == "steamapps" }),
              proof.configurationSHA256.count == 64,
              proof.configurationSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return proof
    }
    private func observe() -> Reading {
        // Default deny: no I/O before proof, current executable identity and the
        // fixed base scope agree. A proof cannot choose another config location.
        guard let proof = Self.decode(consent, identity: identity),
              Self.canonical(driver.defaultSteamapps) == proof.base,
              let data = try? driver.readFile(Self.configurationURL(proof.base), Self.maximumConfigurationBytes),
              data.count <= Self.maximumConfigurationBytes,
              Self.fingerprint(data) == proof.configurationSHA256,
              let roots = Self.libraryRoots(data, base: proof.base), roots == proof.roots else { return Reading() }
        var result = Reading(downloading: false, complete: true)
        var manifestsRemaining = Self.maximumManifests
        var walkRemaining = Self.maximumWalkEntries
        for root in roots {
            let library = URL(fileURLWithPath: root, isDirectory: true)
            guard let listing = try? driver.contents(library, Self.maximumDirectoryEntries),
                  listing.entries.count <= Self.maximumDirectoryEntries else { result.complete = false; continue }
            result.complete = result.complete && listing.complete
            var flagged = false
            for entry in listing.entries {
                guard Self.safeName(entry.name) else { result.complete = false; continue }
                guard entry.name.hasPrefix("appmanifest_") && entry.name.hasSuffix(".acf") else { continue }
                guard manifestsRemaining > 0 else { result.complete = false; break }
                manifestsRemaining -= 1
                guard entry.kind == .regularFile,
                      let bytes = try? driver.readFile(library.appendingPathComponent(entry.name), Self.maximumManifestBytes),
                      bytes.count <= Self.maximumManifestBytes,
                      let text = String(data: bytes, encoding: .utf8),
                      let flags = SteamDownload.stateFlags(fromACF: text) else { result.complete = false; continue }
                flagged = flagged || SteamDownload.isActive(stateFlags: flags)
            }
            if flagged {
                let recent = recentWrite(library.appendingPathComponent("downloading", isDirectory: true), remaining: &walkRemaining)
                result.downloading = result.downloading || recent.downloading
                result.complete = result.complete && recent.complete
            }
        }
        return result
    }
    private func recentWrite(_ directory: URL, remaining: inout Int) -> Reading {
        var result = Reading(downloading: false, complete: true)
        let cutoff = driver.now().addingTimeInterval(-SteamDownload.writeRecencyWindow)
        var pending: [(URL, Int)] = [(directory, 0)]
        while let (next, depth) = pending.popLast() {
            guard remaining > 0, depth <= Self.maximumWalkDepth,
                  let listing = try? driver.contents(next, min(remaining, Self.maximumDirectoryEntries)),
                  listing.entries.count <= min(remaining, Self.maximumDirectoryEntries) else { result.complete = false; continue }
            result.complete = result.complete && listing.complete
            // An incomplete production enumeration may have spent its entire
            // budget on failed metadata. Charge its requested bound, not only
            // the verified subset, so failures cannot expand the global walk.
            remaining -= listing.complete ? max(1, listing.entries.count) : min(remaining, Self.maximumDirectoryEntries)
            for entry in listing.entries {
                guard Self.safeName(entry.name) else { result.complete = false; continue }
                guard !entry.name.hasPrefix(".") else { continue }
                switch entry.kind {
                case .regularFile:
                    guard let modified = entry.modified else { result.complete = false; continue }
                    if modified > cutoff { result.downloading = true }
                case .directory:
                    pending.append((next.appendingPathComponent(entry.name, isDirectory: true), depth + 1))
                case .symbolicLink, .other: result.complete = false
                }
            }
        }
        return result
    }
    private static func configurationURL(_ base: String) -> URL {
        URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("libraryfolders.vdf")
    }
    private static func validIdentity(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 }
    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }
    private static func canonical(_ url: URL) -> String? {
        guard url.isFileURL, url.baseURL == nil, url.host?.isEmpty != false,
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
              url.path.hasPrefix("/"), !url.path.contains("\0"), url.path.utf8.count <= 4_096 else { return nil }
        // Foundation's standardizedFileURL may rewrite /private paths through
        // a symlink alias. Normalize lexically, without resolving or probing.
        var components: [Substring] = []
        for component in url.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else { components.append(component) }
        }
        guard !components.isEmpty else { return nil }
        return "/" + components.joined(separator: "/")
    }
    private static func libraryRoots(_ data: Data, base: String) -> [String]? {
        guard let text = String(data: data, encoding: .utf8), let grammarPaths = validVDF(text) else { return nil }
        let paths = SteamDownload.libraryPaths(fromVDF: text)
        // The pinned extractor intentionally reads one path per line. Reject a
        // layout it cannot fully parse rather than silently omit a library.
        // Counts alone are insufficient: a commented path can replace a real
        // second path on another line. Require the exact ordered values.
        guard !paths.isEmpty, paths == grammarPaths, paths.count <= maximumRoots else { return nil }
        var roots: Set<String> = [base]
        for path in paths {
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096,
                  let canonical = canonical(URL(fileURLWithPath: path)), canonical == (path.hasSuffix("/") ? String(path.dropLast()) : path),
                  let root = Self.canonical(URL(fileURLWithPath: canonical).appendingPathComponent("steamapps", isDirectory: true)) else { return nil }
            roots.insert(root)
        }
        guard roots.count <= maximumRoots else { return nil }
        return roots.sorted()
    }
    // Validate the quoted-key/value VDF grammar before using the pinned path
    // extractor. Its regex alone accepts truncated/garbage configuration.
    private static func validVDF(_ text: String) -> [String]? {
        let chars = Array(text)
        var index = 0
        var depth = 0
        var tokensAtDepth = [0]
        var quoted = false
        var rootName: String?
        var pathValues: [String] = []
        var pathKeyAtDepth = [false]
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace { index += 1; continue }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { index += 1 }; continue
            }
            if char == "\"" {
                index += 1; quoted = false
                let start = index
                while index < chars.count {
                    if chars[index] == "\\" { index += 2; continue }
                    if chars[index] == "\"" { quoted = true; index += 1; break }
                    if chars[index] == "\0" { return nil }
                    index += 1
                }
                guard quoted else { return nil }
                let value = String(chars[start..<(index - 1)])
                if rootName == nil { rootName = value }
                if tokensAtDepth[depth] % 2 == 0 {
                    pathKeyAtDepth[depth] = value == "path"
                } else if pathKeyAtDepth[depth] {
                    // Match only the pinned helper's backslash unescaping;
                    // other ambiguous quoting fails the exact-value check.
                    pathValues.append(value.replacingOccurrences(of: "\\\\", with: "\\"))
                }
                tokensAtDepth[depth] += 1
            } else if char == "{" {
                guard tokensAtDepth[depth] % 2 == 1, !pathKeyAtDepth[depth], depth < 16 else { return nil }
                tokensAtDepth[depth] += 1; depth += 1; tokensAtDepth.append(0); pathKeyAtDepth.append(false); index += 1
            } else if char == "}" {
                guard depth > 0, tokensAtDepth[depth] % 2 == 0 else { return nil }
                tokensAtDepth.removeLast(); pathKeyAtDepth.removeLast(); depth -= 1; index += 1
            } else { return nil }
        }
        guard depth == 0, tokensAtDepth[0] == 2, rootName?.lowercased() == "libraryfolders" else { return nil }
        return pathValues
    }
}

/// All path components are opened without following symlinks. Directory walks
/// use fstatat metadata, and only config/manifest callers read file contents.
enum SteamMetadataIO {
    enum Failure: Error { case unavailable; case system(operation: String, code: Int32) }
    private static func openDirectory(_ url: URL) throws -> Int32 {
        let path = url.path
        guard path.hasPrefix("/") else { throw Failure.unavailable }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.system(operation: "open root", code: errno) }
        for part in path.split(separator: "/") {
            guard part != ".", part != ".." else { close(fd); throw Failure.unavailable }
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            let failureCode = errno
            close(fd)
            guard next >= 0 else { throw Failure.system(operation: "open directory component", code: failureCode) }
            fd = next
        }
        return fd
    }
    static func readFile(_ url: URL, maximum: Int) throws -> Data {
        let parent = try openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.system(operation: "open bookkeeping file", code: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw Failure.system(operation: "bookkeeping file metadata", code: errno) }
        var data = Data(count: maximum + 1)
        let count = data.withUnsafeMutableBytes { buffer in Darwin.read(fd, buffer.baseAddress, maximum + 1) }
        guard count >= 0, count <= maximum, count == info.st_size else { throw Failure.system(operation: "read bookkeeping file", code: errno) }
        data.count = count
        return data
    }
    /// Both production readdir/fstatat and tests use this bounded aggregation.
    /// A failed sibling never erases verified metadata; every attempted entry
    /// counts toward the bound, including entries whose stat fails.
    static func enumerate(maximum: Int, next: () throws -> String?, metadata: (String) throws -> CompanionSteamFileDriver.Entry) -> CompanionSteamFileDriver.Listing {
        var entries: [CompanionSteamFileDriver.Entry] = []; var complete = true; var inspected = 0
        do {
            while let name = try next() {
                if name == "." || name == ".." { continue }
                guard inspected < maximum else { return .init(entries: entries, complete: false) }
                inspected += 1
                do { entries.append(try metadata(name)) }
                catch { complete = false }
            }
        } catch { complete = false }
        return .init(entries: entries, complete: complete)
    }
    static func contents(_ url: URL, maximum: Int) throws -> CompanionSteamFileDriver.Listing {
        let fd = try openDirectory(url)
        guard let directory = fdopendir(fd) else { close(fd); throw Failure.unavailable }
        defer { closedir(directory) }
        return enumerate(maximum: maximum, next: {
            // Clear errno immediately before each readdir: a sibling fstatat
            // failure is not evidence that directory iteration itself failed.
            errno = 0
            guard let pointer = readdir(directory) else {
                guard errno == 0 else { throw Failure.unavailable }
                return nil
            }
            return withUnsafePointer(to: &pointer.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
        }, metadata: { name in
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unavailable }
            let kind: CompanionSteamFileDriver.Entry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFREG: kind = .regularFile
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symbolicLink
            default: kind = .other
            }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            return .init(name: name, kind: kind, modified: modified)
        })
    }
}
