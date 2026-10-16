import Foundation

/// Disposable files for Finder. Explicit user saves do not go through this cache.
final class TemporaryImageExports {
    private let fileManager: FileManager
    private let directories: [URL]
    private let directory: URL
    private let maximumAge: TimeInterval
    private let maximumBytes: Int64
    private let lock = NSLock()

    init(fileManager: FileManager = .default, directory: URL? = nil,
         maximumAge: TimeInterval = 24 * 60 * 60, maximumBytes: Int64 = 256 * 1_024 * 1_024) {
        precondition(maximumAge > 0 && maximumBytes > 0)
        self.fileManager = fileManager
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        if let directory {
            self.directory = directory
            directories = [directory]
        } else {
            let container = fileManager.temporaryDirectory.appendingPathComponent("local.bufera.app", isDirectory: true)
            self.directory = container.appendingPathComponent("ImageExports", isDirectory: true)
            directories = [container, self.directory]
        }
    }

    func file(data: Data, id: Int64, fileExtension: String) throws -> URL {
        guard id > 0, !data.isEmpty, Int64(data.count) <= maximumBytes,
              fileExtension.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        let url = directory.appendingPathComponent("Bufera-\(id).\(fileExtension)")
        if let attributes = try attributesIfPresent(url), !isOwnedRegularFile(attributes) {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        try prune(excluding: url)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600, .modificationDate: Date()], ofItemAtPath: url.path)
        try prune(excluding: url)
        return url
    }

    func cleanup() throws {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        try prune()
    }

    private func prepareDirectory() throws {
        for url in directories {
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
    }

    private struct Entry {
        let url: URL
        let modified: Date
        let bytes: Int64
    }

    private func prune(excluding protectedURL: URL? = nil) throws {
        let deadline = Date().addingTimeInterval(-maximumAge)
        var entries: [Entry] = []
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.lastPathComponent.range(of: "^Bufera-[1-9][0-9]*\\.[a-z0-9]{1,10}$", options: .regularExpression) != nil,
                  let attributes = try attributesIfPresent(url), isOwnedRegularFile(attributes),
                  let modified = attributes[.modificationDate] as? Date,
                  let bytes = attributes[.size] as? NSNumber else { continue }
            if modified < deadline && url != protectedURL {
                try fileManager.removeItem(at: url)
            } else {
                entries.append(Entry(url: url, modified: modified, bytes: bytes.int64Value))
            }
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) where total > maximumBytes && entry.url != protectedURL {
            try fileManager.removeItem(at: entry.url)
            total -= entry.bytes
        }
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
