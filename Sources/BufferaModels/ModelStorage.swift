import CryptoKit
import Foundation

struct ModelReceipt: Codable {
    let revision: String
    let sha256: String
    let state: ModelState
    let enabled: Bool
    let error: String?
}

final class ModelVerification: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

enum ModelStorage {
    static func validate(_ descriptor: LocalModelDescriptor) throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let source = descriptor.sourceURL
        let isHub = source.scheme == "https" && source.host == "huggingface.co"
        let isFixture = source.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(source.host ?? "")
        guard descriptor.revision.count == 40, descriptor.revision.unicodeScalars.allSatisfy(hex.contains),
              descriptor.sha256.count == 64, descriptor.sha256.unicodeScalars.allSatisfy(hex.contains),
              descriptor.byteCount > 0, !descriptor.filename.isEmpty,
              descriptor.filename != ".", descriptor.filename != "..",
              !descriptor.filename.contains("/"), !descriptor.filename.contains("\\"),
              !descriptor.filename.contains("\0"), isHub || isFixture else {
            throw ModelStorageError.invalidDescriptor
        }
    }

    static func createDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ModelStorageError.unsafeFile
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        // URL resource values cache fileSize on that URL instance, including before
        // a resumed write. A fresh stat is essential before integrity verification.
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return 0
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ModelStorageError.unsafeFile
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func verify(_ url: URL, descriptor: LocalModelDescriptor, token: ModelVerification) throws {
        guard try fileSize(url) == descriptor.byteCount else { throw ModelStorageError.unexpectedSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try token.checkCancellation()
            let data = try autoreleasepool { try handle.read(upToCount: 1024 * 1024) }
            guard let data, !data.isEmpty else { break }
            count += Int64(data.count)
            hash.update(data: data)
        }
        try token.checkCancellation()
        guard count == descriptor.byteCount else { throw ModelStorageError.unexpectedSize }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == descriptor.sha256 else { throw ModelStorageError.checksum }
    }
}
