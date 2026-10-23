import Foundation
/// One instance per central; no state crosses peers. Error is terminal for its owner.
public final class FrameDecoder {
    private var buffer = Data(); private var began: TimeInterval?
    public init() {}
    public static func frame(_ record: Data) throws -> Data {
        guard !record.isEmpty, record.count <= 65536 else { throw CompanionError.limit }
        let n = UInt32(record.count)
        return Data([UInt8(n >> 24),UInt8((n >> 16)&255),UInt8((n >> 8)&255),UInt8(n&255)]) + record
    }
    public func feed(_ chunk: Data, now: TimeInterval) throws -> [Data] {
        if let began, now-began > 10 { throw CompanionError.expired }
        guard buffer.count + chunk.count <= 131080 else { throw CompanionError.limit }
        if !chunk.isEmpty, buffer.isEmpty { began=now }
        buffer.append(chunk); var records: [Data]=[]
        while buffer.count >= 4 {
            let n = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard n>0, n<=65536 else { throw CompanionError.limit }
            guard buffer.count>=n+4 else { break }
            let payload=Data(buffer.dropFirst(4).prefix(n)); guard String(data: payload, encoding: .utf8) != nil else { throw CompanionError.invalid }
            records.append(payload); buffer.removeFirst(n+4); began = buffer.isEmpty ? nil : now
        }
        return records
    }
    public func checkTimeout(now: TimeInterval) throws { if let began, now-began>10 { throw CompanionError.expired } }
}
/// Queue owns unconsumed bytes, advances only after CoreBluetooth accepts a chunk.
public final class NotificationQueue {
    private var chunks: [Data] = []; public private(set) var bytes = 0
    public init() {}
    public func enqueue(record: Data, mtu: Int) throws {
        let framed=try FrameDecoder.frame(record)
        guard mtu>0, bytes+framed.count<=262144, chunks.count + (framed.count+mtu-1)/mtu <= 8192 else { throw CompanionError.limit }
        for offset in stride(from:0,to:framed.count,by:mtu) { chunks.append(Data(framed[offset..<min(offset+mtu,framed.count)])) }
        bytes+=framed.count
    }
    public var next: Data? { chunks.first }
    public func accepted() { if !chunks.isEmpty { bytes-=chunks.removeFirst().count } }
}
