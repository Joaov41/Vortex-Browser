import Compression
import Foundation
import zlib

/// Minimal read-only ZIP reader for the uBlock Origin Lite release archives (Stored and Deflate entries).
/// Every extracted entry is CRC-32 checked against the archive's own record.
nonisolated struct ZipArchive: Sendable {
    struct Entry: Sendable {
        let path: String
        let compressedSize: Int
        let uncompressedSize: Int
        let crc32: UInt32
        let method: UInt16
        fileprivate let localHeaderOffset: Int
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum Error: Swift.Error, LocalizedError {
        case malformed(String), unsupportedMethod(UInt16, String), checksumMismatch(String), unsafePath(String)
        var errorDescription: String? {
            switch self {
            case .malformed(let detail): "The archive is malformed: \(detail)."
            case .unsupportedMethod(let method, let path): "Unsupported compression method \(method) for \(path)."
            case .checksumMismatch(let path): "Checksum mismatch for \(path)."
            case .unsafePath(let path): "Unsafe entry path \(path)."
            }
        }
    }

    let data: Data
    let entries: [Entry]

    init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
    }

    init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    func entry(named path: String) -> Entry? { entries.first { $0.path == path } }

    func contents(of entry: Entry) throws -> Data {
        let base = data.startIndex + entry.localHeaderOffset
        guard base + 30 <= data.endIndex, readUInt32(at: base) == 0x0403_4b50 else { throw Error.malformed("local header for \(entry.path)") }
        let nameLength = Int(readUInt16(at: base + 26)), extraLength = Int(readUInt16(at: base + 28))
        let start = base + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start <= end, end <= data.endIndex else { throw Error.malformed("data range for \(entry.path)") }
        let compressed = data[start..<end]
        let output: Data
        switch entry.method {
        case 0: output = Data(compressed)
        case 8: output = try Self.inflate(compressed, expectedSize: entry.uncompressedSize, path: entry.path)
        default: throw Error.unsupportedMethod(entry.method, entry.path)
        }
        guard output.count == entry.uncompressedSize, Self.crc32(output) == entry.crc32 else { throw Error.checksumMismatch(entry.path) }
        return output
    }

    /// Extracts every entry below `directory`, rejecting paths that escape it.
    func extract(to directory: URL, including filter: (Entry) -> Bool = { _ in true }) throws {
        let fileManager = FileManager.default
        for entry in entries where filter(entry) {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains(".."), !components.contains(where: \.isEmpty), !entry.path.hasPrefix("/") else {
                throw Error.unsafePath(entry.path)
            }
            let destination = components.reduce(directory) { $0.appendingPathComponent($1) }
            if entry.isDirectory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents(of: entry).write(to: destination, options: .atomic)
        }
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        // End of central directory record: signature 0x06054b50, at least 22 bytes, optional comment (max 65535).
        let minimum = 22
        guard data.count >= minimum else { throw Error.malformed("too small") }
        var eocd: Int?
        var probe = data.endIndex - minimum
        let lowest = max(data.startIndex, data.endIndex - minimum - 65535)
        while probe >= lowest {
            if data.readUInt32(at: probe) == 0x0605_4b50 { eocd = probe; break }
            probe -= 1
        }
        guard let eocd else { throw Error.malformed("missing end of central directory") }
        let count = Int(data.readUInt16(at: eocd + 10))
        let directorySize = Int(data.readUInt32(at: eocd + 12))
        let directoryOffset = Int(data.readUInt32(at: eocd + 16))
        guard count != 0xffff, directorySize != 0xffff_ffff, directoryOffset != 0xffff_ffff else { throw Error.malformed("ZIP64 archives are not supported") }
        var cursor = data.startIndex + directoryOffset
        let directoryEnd = cursor + directorySize
        guard directoryEnd <= data.endIndex else { throw Error.malformed("central directory range") }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 46 <= directoryEnd, data.readUInt32(at: cursor) == 0x0201_4b50 else { throw Error.malformed("central directory entry") }
            let flags = data.readUInt16(at: cursor + 8)
            let method = data.readUInt16(at: cursor + 10)
            let crc = data.readUInt32(at: cursor + 16)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localHeaderOffset = Int(data.readUInt32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= directoryEnd else { throw Error.malformed("entry name") }
            guard flags & 0x1 == 0 else { throw Error.malformed("encrypted entry") }
            guard let path = String(bytes: data[nameStart..<nameStart + nameLength], encoding: .utf8) else { throw Error.malformed("entry name encoding") }
            entries.append(Entry(path: path, compressedSize: compressedSize, uncompressedSize: uncompressedSize, crc32: crc, method: method, localHeaderOffset: localHeaderOffset))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ input: Data, expectedSize: Int, path: String) throws -> Data {
        guard expectedSize >= 0 else { throw Error.malformed("size for \(path)") }
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.baseAddress, let sourceBase = source.baseAddress else { return 0 }
                // COMPRESSION_ZLIB decodes the raw Deflate stream that ZIP stores (no zlib header).
                return compression_decode_buffer(destinationBase.assumingMemoryBound(to: UInt8.self), expectedSize, sourceBase.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw Error.malformed("inflate produced \(written) of \(expectedSize) bytes for \(path)") }
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer -> UInt32 in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, base.assumingMemoryBound(to: Bytef.self), uInt(buffer.count)))
        }
    }

    private func readUInt16(at offset: Int) -> UInt16 { data.readUInt16(at: offset) }
    private func readUInt32(at offset: Int) -> UInt32 { data.readUInt32(at: offset) }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
