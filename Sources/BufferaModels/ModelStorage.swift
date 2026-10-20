import CryptoKit
import Darwin
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

/// A successful hash is trusted only inside this process and for this exact file version.
/// ctime catches rewrites even if a caller restores the old mtime; inode/birthtime catch replacement.
private struct VerifiedModelFile: Hashable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let createdSeconds: Int64
    let createdNanoseconds: Int64

    init(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFREG else { throw ModelStorageError.unsafeFile }
        device = Int64(value.st_dev)
        inode = UInt64(value.st_ino)
        size = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        createdSeconds = Int64(value.st_birthtimespec.tv_sec)
        createdNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
    }
}

private final class ModelVerificationCache: @unchecked Sendable {
    struct Key: Hashable {
        let file: VerifiedModelFile
        let revision: String
        let sha256: String
    }

    static let shared = ModelVerificationCache()
    private let lock = NSLock()
    private var keys = Set<Key>()
    private var order: [Key] = []

    func contains(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.contains(key)
    }

    func insert(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard keys.insert(key).inserted else { return }
        order.append(key)
        if order.count > 16 { keys.remove(order.removeFirst()) }
    }
}

enum ModelVerificationOutcome: Equatable, Sendable { case hashed, reused }

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

    @discardableResult
    static func verify(_ url: URL, descriptor: LocalModelDescriptor,
                       token: ModelVerification) throws -> ModelVerificationOutcome {
        try token.checkCancellation()
        let descriptorFD = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptorFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptorFD, closeOnDealloc: true)
        defer { try? handle.close() }
        let identity = try fileIdentity(descriptorFD)
        guard identity.size == descriptor.byteCount else { throw ModelStorageError.unexpectedSize }
        guard try fileIdentity(url) == identity else { throw ModelStorageError.unsafeFile }
        let key = ModelVerificationCache.Key(file: identity, revision: descriptor.revision,
                                             sha256: descriptor.sha256)
        if ModelVerificationCache.shared.contains(key) {
            try token.checkCancellation()
            guard try fileIdentity(descriptorFD) == identity, try fileIdentity(url) == identity else {
                throw ModelStorageError.unsafeFile
            }
            return .reused
        }

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
        guard try fileIdentity(descriptorFD) == identity, try fileIdentity(url) == identity else {
            throw ModelStorageError.unsafeFile
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == descriptor.sha256 else { throw ModelStorageError.checksum }
        try token.checkCancellation()
        ModelVerificationCache.shared.insert(key)
        return .hashed
    }

    private static func fileIdentity(_ descriptor: Int32) throws -> VerifiedModelFile {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try VerifiedModelFile(value)
    }

    private static func fileIdentity(_ url: URL) throws -> VerifiedModelFile {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try VerifiedModelFile(value)
    }
}
