import Compression
import Foundation

/// A folder read from an exported bookmarks file, with its subfolders and links.
nonisolated struct BookmarkImportFolder: Equatable {
    var title: String
    var folders: [BookmarkImportFolder] = []
    var links: [BookmarkImportLink] = []

    /// Links in this folder and every subfolder.
    var linkCount: Int {
        links.count + folders.reduce(0) { $0 + $1.linkCount }
    }

    var folderCount: Int {
        folders.count + folders.reduce(0) { $0 + $1.folderCount }
    }
}

nonisolated struct BookmarkImportLink: Equatable {
    var title: String
    var url: URL
    var icon: Data?
}

/// Reads the Netscape bookmarks format that Safari, Chrome, Edge, Firefox and
/// Brave all use for "Export Bookmarks":
///
///     <DT><H3>Folder</H3>
///     <DL><p>
///         <DT><A HREF="https://…" ICON="data:image/png;base64,…">Title</A>
///     </DL><p>
nonisolated enum BookmarkFileParser {
    enum ParseError: LocalizedError {
        case notBookmarkFile
        case noLinks
        case noBookmarksInArchive

        var errorDescription: String? {
            switch self {
            case .notBookmarkFile:
                return "This file isn't a bookmarks export. In your other browser, use Export Bookmarks and choose the .html file it saves."
            case .noLinks:
                return "This bookmarks file has no web links to import."
            case .noBookmarksInArchive:
                return "This zip has no bookmarks in it. In Safari, use File → Export Browsing Data to File and tick Bookmarks."
            }
        }
    }

    /// Exported favicons above this size are dropped rather than stored.
    private static let maxIconBytes = 32_768

    static func isBookmarkFile(_ html: String) -> Bool {
        let head = String(html.prefix(4_096))
        if head.range(of: "NETSCAPE-Bookmark-file", options: .caseInsensitive) != nil {
            return true
        }
        // Some tools omit the doctype; the <DL> list of <DT><A> links is the signature.
        return html.range(of: "<DL", options: .caseInsensitive) != nil
            && html.range(of: "<DT><A", options: .caseInsensitive) != nil
    }

    /// Accepts a bookmarks .html file, or a .zip that contains one, such as
    /// Safari's File → Export Browsing Data to File.
    static func parse(data: Data) throws -> BookmarkImportFolder {
        guard ZipArchiveReader.isZip(data) else {
            return try parse(text(from: data))
        }
        var exports: [(name: String, folder: BookmarkImportFolder)] = []
        for entry in try ZipArchiveReader.entries(in: data) where entry.name.lowercased().hasSuffix(".html") {
            let html = text(from: try ZipArchiveReader.contents(of: entry, in: data))
            guard isBookmarkFile(html), let folder = try? parse(html) else { continue }
            exports.append((entry.name, folder))
        }
        guard !exports.isEmpty else { throw ParseError.noBookmarksInArchive }
        if exports.count == 1 { return exports[0].folder }
        // Several Safari profiles export one file each; keep each as its own folder.
        var root = BookmarkImportFolder(title: "")
        for export in exports {
            var folder = export.folder
            // Name it after the profile's folder ("Personal/Bookmarks.html"), else the file.
            let path = export.name as NSString
            let parent = path.deletingLastPathComponent
            folder.title = parent.isEmpty
                ? (path.lastPathComponent as NSString).deletingPathExtension
                : (parent as NSString).lastPathComponent
            root.folders.append(folder)
        }
        return root
    }

    private static func text(from data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    static func parse(_ html: String) throws -> BookmarkImportFolder {
        guard isBookmarkFile(html) else { throw ParseError.notBookmarkFile }

        let source = html as NSString
        let tagPattern = try! NSRegularExpression(pattern: "<(/?)(dl|h3|a)\\b([^>]*)>", options: [.caseInsensitive])
        let matches = tagPattern.matches(in: html, range: NSRange(location: 0, length: source.length))

        var stack = [BookmarkImportFolder(title: "")]
        var pendingFolderTitle: String?
        var openedRootList = false

        for match in matches {
            let isClosing = source.substring(with: match.range(at: 1)) == "/"
            let tag = source.substring(with: match.range(at: 2)).lowercased()
            let attributes = source.substring(with: match.range(at: 3))
            let contentStart = match.range.location + match.range.length

            switch (tag, isClosing) {
            case ("h3", false):
                pendingFolderTitle = text(in: source, from: contentStart, until: "</h3>")
            case ("dl", false):
                if let title = pendingFolderTitle {
                    stack.append(BookmarkImportFolder(title: title.isEmpty ? "Untitled Folder" : title))
                    pendingFolderTitle = nil
                } else if openedRootList {
                    // A list without a heading still nests; keep its links grouped.
                    stack.append(BookmarkImportFolder(title: "Untitled Folder"))
                }
                openedRootList = true
            case ("dl", true):
                guard stack.count > 1 else { continue }
                let folder = stack.removeLast()
                if folder.linkCount > 0 {
                    stack[stack.count - 1].folders.append(folder)
                }
            case ("a", false):
                let values = attributeValues(in: attributes)
                guard let href = values["href"].map(decodeEntities),
                      let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    continue
                }
                let title = text(in: source, from: contentStart, until: "</a>")
                stack[stack.count - 1].links.append(
                    BookmarkImportLink(
                        title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
                        url: url,
                        icon: values["icon"].flatMap(iconData)
                    )
                )
            default:
                continue
            }
        }

        // Fold any lists the file never closed back into their parents.
        while stack.count > 1 {
            let folder = stack.removeLast()
            if folder.linkCount > 0 {
                stack[stack.count - 1].folders.append(folder)
            }
        }

        var root = stack[0]
        // Exports wrap everything in one top folder ("Bookmarks", "Bookmarks bar");
        // unwrap it so the import folder isn't one level deeper than needed.
        while root.links.isEmpty, root.folders.count == 1 {
            root = root.folders[0]
        }
        guard root.linkCount > 0 else { throw ParseError.noLinks }
        return root
    }

    // MARK: Helpers

    /// Visible text from `start` to the closing tag, with nested tags and entities removed.
    private static func text(in source: NSString, from start: Int, until closingTag: String) -> String {
        let searchRange = NSRange(location: start, length: source.length - start)
        let closing = source.range(of: closingTag, options: .caseInsensitive, range: searchRange)
        let end = closing.location == NSNotFound ? min(source.length, start + 512) : closing.location
        let raw = source.substring(with: NSRange(location: start, length: end - start))
        let withoutTags = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return decodeEntities(withoutTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attributeValues(in attributes: String) -> [String: String] {
        let pattern = try! NSRegularExpression(pattern: "([A-Za-z_:-]+)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')")
        let source = attributes as NSString
        var values: [String: String] = [:]
        for match in pattern.matches(in: attributes, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
            let valueRange = match.range(at: 3).location != NSNotFound ? match.range(at: 3) : match.range(at: 4)
            values[name] = source.substring(with: valueRange)
        }
        return values
    }

    private static func iconData(_ value: String) -> Data? {
        guard value.hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ","),
              value[..<comma].hasSuffix(";base64") else {
            return nil
        }
        let encoded = value[value.index(after: comma)...]
        guard encoded.count <= maxIconBytes * 4 / 3 + 4,
              let data = Data(base64Encoded: String(encoded)),
              data.count <= maxIconBytes else {
            return nil
        }
        return data
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);")
        let source = result as NSString
        for match in numeric.matches(in: result, range: NSRange(location: 0, length: source.length)).reversed() {
            let isHex = source.substring(with: match.range(at: 1)).lowercased() == "x"
            let digits = source.substring(with: match.range(at: 2))
            guard let value = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(value) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
        }
        // Last, so "&amp;lt;" becomes "&lt;" rather than "<".
        return result.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }
}

/// Reads files out of a .zip archive (stored or deflated entries), which is
/// all a browser's export needs. iOS has no public unzip API.
nonisolated enum ZipArchiveReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ReadError: LocalizedError {
        case unreadable
        case unsupported

        var errorDescription: String? {
            switch self {
            case .unreadable: return "This zip file couldn't be read. Try exporting it again."
            case .unsupported: return "This zip file uses a format Vortex can't open. Unzip it in the Files app and import the .html file inside."
            }
        }
    }

    /// Bookmark exports are small; anything larger isn't one.
    private static let maxEntrySize = 64 * 1_024 * 1_024

    static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    static func entries(in data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        // The end-of-central-directory record sits in the last 64 KB + 22 bytes.
        let searchStart = max(0, bytes.count - 65_557)
        guard bytes.count >= 22,
              let end = stride(from: bytes.count - 22, through: searchStart, by: -1)
                .first(where: { uint32(bytes, $0) == 0x0605_4B50 }) else {
            throw ReadError.unreadable
        }
        let count = Int(uint16(bytes, end + 10))
        var offset = Int(uint32(bytes, end + 16))
        guard offset != 0xFFFF_FFFF, count != 0xFFFF else { throw ReadError.unsupported }

        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, uint32(bytes, offset) == 0x0201_4B50 else { throw ReadError.unreadable }
            let nameLength = Int(uint16(bytes, offset + 28))
            let extraLength = Int(uint16(bytes, offset + 30))
            let commentLength = Int(uint16(bytes, offset + 32))
            guard offset + 46 + nameLength <= bytes.count else { throw ReadError.unreadable }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(
                name: name,
                method: uint16(bytes, offset + 10),
                compressedSize: Int(uint32(bytes, offset + 20)),
                uncompressedSize: Int(uint32(bytes, offset + 24)),
                localHeaderOffset: Int(uint32(bytes, offset + 42))
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        // Skip folders and the resource forks macOS adds under __MACOSX/.
        return entries.filter { !$0.name.hasSuffix("/") && !$0.name.hasPrefix("__MACOSX/") }
    }

    static func contents(of entry: Entry, in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, uint32(bytes, header) == 0x0403_4B50 else { throw ReadError.unreadable }
        let start = header + 30 + Int(uint16(bytes, header + 26)) + Int(uint16(bytes, header + 28))
        guard entry.compressedSize <= maxEntrySize, entry.uncompressedSize <= maxEntrySize,
              start + entry.compressedSize <= bytes.count else {
            throw ReadError.unsupported
        }
        let compressed = Array(bytes[start..<(start + entry.compressedSize)])

        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            // COMPRESSION_ZLIB is raw DEFLATE, the format zip entries use.
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = [UInt8](repeating: 0, count: entry.uncompressedSize)
            let written = compression_decode_buffer(
                &output, output.count,
                compressed, compressed.count,
                nil, COMPRESSION_ZLIB
            )
            guard written == entry.uncompressedSize else { throw ReadError.unreadable }
            return Data(output)
        default:
            throw ReadError.unsupported
        }
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
