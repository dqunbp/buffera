import Foundation

/// Disposable files for Finder and drag destinations. Explicit user saves do not go through this cache.
final class TemporaryImageExports {
    private let fileManager: FileManager
    private let directories: [URL]
    private let directory: URL
    private let legacyDirectory: URL?
    private let maximumAge: TimeInterval
    private let maximumBytes: Int64
    private let lock = NSLock()

    init(fileManager: FileManager = .default, directory: URL? = nil, legacyDirectory: URL? = nil,
         maximumAge: TimeInterval = 24 * 60 * 60, maximumBytes: Int64 = 256 * 1_024 * 1_024) {
        precondition(maximumAge > 0 && maximumBytes > 0)
        self.fileManager = fileManager
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        if let directory {
            self.directory = directory
            directories = [directory]
            self.legacyDirectory = legacyDirectory
        } else {
            let container = fileManager.temporaryDirectory.appendingPathComponent("local.buffera.app", isDirectory: true)
            self.directory = container.appendingPathComponent("ImageExports", isDirectory: true)
            directories = [container, self.directory]
            // Compatibility only: exports created before the Buffera rename expire normally.
            self.legacyDirectory = legacyDirectory ?? fileManager.temporaryDirectory
                .appendingPathComponent("local.bufera.app", isDirectory: true)
                .appendingPathComponent("ImageExports", isDirectory: true)
        }
    }

    struct Image {
        let data: Data
        let fileExtension: String
        var itemIndex: Int? = nil
        var basename: String? = nil
    }

    func file(data: Data, id: Int64, fileExtension: String, basename: String? = nil) throws -> URL {
        try files([Image(data: data, fileExtension: fileExtension, basename: basename)], id: id)[0]
    }

    /// Export a whole drag together so cache eviction cannot remove another
    /// image from the same record while preparing its later items.
    func files(_ images: [Image], id: Int64) throws -> [URL] {
        guard id > 0, !images.isEmpty,
              images.reduce(Int64(0), { $0 + Int64($1.data.count) }) <= maximumBytes,
              images.allSatisfy({ !$0.data.isEmpty && ($0.itemIndex ?? 0) >= 0 &&
                  ($0.basename == nil || (Self.validBasename($0.basename!) && ["txt", "md"].contains($0.fileExtension))) &&
                  $0.fileExtension.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        let urls = try images.map { image in
            if let basename = image.basename {
                let folder = directory.appendingPathComponent("Text-\(id)", isDirectory: true)
                try prepareDirectory(folder)
                return folder.appendingPathComponent("\(basename).\(image.fileExtension)")
            }
            let suffix = image.itemIndex.map { "-\($0)" } ?? ""
            return directory.appendingPathComponent("Buffera-\(id)\(suffix).\(image.fileExtension)")
        }
        guard Set(urls).count == urls.count else { throw CocoaError(.fileWriteInvalidFileName) }
        for url in urls {
            if let attributes = try attributesIfPresent(url), !isOwnedRegularFile(attributes) {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let protected = Set(urls)
        try prune(excluding: protected)
        for (image, url) in zip(images, urls) {
            try image.data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600, .modificationDate: Date()], ofItemAtPath: url.path)
        }
        try prune(excluding: protected)
        return urls
    }

    func cleanup() throws {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        try prune()
    }

    private static func validBasename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 180 &&
            !name.hasPrefix(".") && name.rangeOfCharacter(from:
                CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil
    }

    private func prepareDirectory() throws {
        for url in directories { try prepareDirectory(url) }
    }

    private func prepareDirectory(_ url: URL) throws {
        if let attributes = try attributesIfPresent(url) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private struct Entry {
        let url: URL
        let modified: Date
        let bytes: Int64
    }

    private func prune(excluding protectedURLs: Set<URL> = []) throws {
        let deadline = Date().addingTimeInterval(-maximumAge)
        let protectedPaths = Set(protectedURLs.map(\.path))
        var entries: [Entry] = []
        var caches = [(directory, "Buffera")]
        if let legacyDirectory = try existingLegacyDirectory() {
            // Never create or rename the old cache, and never write new files into it.
            caches.append((legacyDirectory, "Bufera"))
        }
        var textFolders: [URL] = []
        for (cacheDirectory, prefix) in caches {
            // Rebuild URLs from names: Foundation enumeration can resolve /var to /private/var.
            for name in try fileManager.contentsOfDirectory(atPath: cacheDirectory.path) {
                let url = cacheDirectory.appendingPathComponent(name)
                var candidates: [URL] = []
                if cacheDirectory == directory,
                   url.lastPathComponent.range(of: "^Text-[1-9][0-9]*$", options: .regularExpression) != nil,
                   try attributesIfPresent(url)?[.type] as? FileAttributeType == .typeDirectory {
                    // Only our one-level named export folders are traversed, never links.
                    textFolders.append(url)
                    candidates = try fileManager.contentsOfDirectory(atPath: url.path)
                        .map { url.appendingPathComponent($0) }
                        .filter { ["txt", "md"].contains($0.pathExtension) &&
                            Self.validBasename($0.deletingPathExtension().lastPathComponent) }
                } else if url.lastPathComponent.range(of: "^\(prefix)-[1-9][0-9]*(?:-[0-9]+)?\\.[a-z0-9]{1,10}$", options: .regularExpression) != nil {
                    candidates = [url]
                }
                for candidate in candidates {
                    guard let attributes = try attributesIfPresent(candidate), isOwnedRegularFile(attributes),
                          let modified = attributes[.modificationDate] as? Date,
                          let bytes = attributes[.size] as? NSNumber else { continue }
                    if modified < deadline && !protectedPaths.contains(candidate.path) {
                        try fileManager.removeItem(at: candidate)
                    } else {
                        entries.append(Entry(url: candidate, modified: modified, bytes: bytes.int64Value))
                    }
                }
            }
        }
        // Both generations share one size budget until the old files have expired.
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) where total > maximumBytes && !protectedPaths.contains(entry.url.path) {
            try fileManager.removeItem(at: entry.url)
            total -= entry.bytes
        }
        let protectedFolders = Set(protectedURLs.map { $0.deletingLastPathComponent().path })
        for folder in textFolders where !protectedFolders.contains(folder.path) {
            if try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty {
                try fileManager.removeItem(at: folder)
            }
        }
    }

    private func existingLegacyDirectory() throws -> URL? {
        guard let legacyDirectory, legacyDirectory != directory else { return nil }
        // Reject a redirected container as well as a redirected ImageExports directory.
        for url in [legacyDirectory.deletingLastPathComponent(), legacyDirectory] {
            guard let attributes = try attributesIfPresent(url),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
        }
        return legacyDirectory
    }

    private func isOwnedRegularFile(_ attributes: [FileAttributeKey: Any]) -> Bool {
        // Do not follow symbolic links or modify files linked into this directory.
        attributes[.type] as? FileAttributeType == .typeRegular
            && (attributes[.referenceCount] as? NSNumber)?.intValue == 1
    }

    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try fileManager.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
}
