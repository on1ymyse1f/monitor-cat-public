import Foundation

/// Streaming JSONL reader.
///
/// Log files here reach tens of thousands of lines; this reads in chunks and
/// compacts the buffer once per chunk rather than once per line.
public enum JSONL {
    /// - Parameter needles: when non-empty, lines containing none of these
    ///   byte sequences are skipped **before** JSON parsing. AI logs are mostly
    ///   message-content lines; the accounting lines are a small minority, so
    ///   a cheap substring gate avoids parsing megabytes of prose.
    public static func forEachObject(
        at url: URL,
        needles: [String] = [],
        _ body: ([String: Any]) throws -> Void
    ) throws {
        try forEachLine(at: url, from: 0, needles: needles) { obj, _, _ in try body(obj) }
    }

    /// Offset-aware variant for incremental parsing: seeks to `startOffset`
    /// (must be a line boundary — checkpoints always are), reports each line's
    /// absolute byte offset and the running end offset so callers can checkpoint.
    ///
    /// - Returns: the byte offset just past the last byte read.
    @discardableResult
    public static func forEachLine(
        at url: URL,
        from startOffset: UInt64,
        needles: [String] = [],
        _ body: ([String: Any], _ lineStart: UInt64, _ lineEnd: UInt64) throws -> Void
    ) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if startOffset > 0 { try handle.seek(toOffset: startOffset) }

        let needleBytes = needles.map { Data($0.utf8) }

        var buffer = Data()
        let chunkSize = 1 << 20
        let newline: UInt8 = 0x0A
        var consumed = startOffset   // bytes consumed up to buffer start

        func process(_ line: Data, _ lineStart: UInt64, _ lineEnd: UInt64) throws {
            guard !line.isEmpty else { return }
            if !needleBytes.isEmpty,
               !needleBytes.contains(where: { line.range(of: $0) != nil }) { return }
            // Foundation objects from JSONSerialization are autoreleased; without
            // a pool boundary they accumulate until process exit — gigabytes on
            // large logs. Draining per line keeps peak memory flat.
            try autoreleasepool {
                if let obj = decode(line) { try body(obj, lineStart, lineEnd) }
            }
        }

        func drain(final: Bool) throws {
            var searchFrom = buffer.startIndex
            while let idx = buffer[searchFrom...].firstIndex(of: newline) {
                let line = buffer[searchFrom..<idx]
                let lineStart = consumed + UInt64(searchFrom)
                let lineEnd = consumed + UInt64(idx) + 1   // past the newline
                try process(Data(line), lineStart, lineEnd)
                searchFrom = buffer.index(after: idx)
            }
            if searchFrom > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<searchFrom)
                consumed += UInt64(searchFrom)
            }
            if final, !buffer.isEmpty {
                let lineStart = consumed
                try process(buffer, lineStart, consumed + UInt64(buffer.count))
            }
        }

        while true {
            var done = false
            // Pool per chunk, not per read loop turn: bridged Foundation
            // objects from readData and JSONSerialization are autoreleased and
            // would otherwise pile up until process exit on multi-GB logs.
            try autoreleasepool {
                let chunk = handle.readData(ofLength: chunkSize)
                if chunk.isEmpty { done = true; return }
                buffer.append(chunk)
                try drain(final: false)
            }
            if done { break }
        }
        try autoreleasepool { try drain(final: true) }
        return try handle.offset()
    }

    /// A malformed line is skipped, not fatal. Logs get truncated mid-write when
    /// a tool exits, and one bad tail line should not void an entire session.
    private static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Tolerant accessors. The logs are someone else's format and will drift; these
/// read defensively rather than binding to a generated schema that would throw
/// on an added field.
extension Dictionary where Key == String, Value == Any {
    public func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }

    public func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let d = self[key] as? Double { return Int(d) }
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    public func double(_ key: String) -> Double? {
        if let d = self[key] as? Double { return d }
        if let i = self[key] as? Int { return Double(i) }
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    public func str(_ key: String) -> String? { self[key] as? String }

    public func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        return nil
    }
}

public enum Timestamps {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Both log formats write RFC3339 with a `Z` suffix; fractional seconds are
    /// present in Codex and may or may not be in Claude Code.
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return withFraction.date(from: value) ?? plain.date(from: value)
    }
}
