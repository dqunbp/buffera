import Foundation

/// Each worker owns a separate writable cache. Model stores and external weights stay read-only.
public struct LiteRTRuntimeCache: Sendable {
    public let url: URL

    public init(role: ModelRole, rootURL: URL? = nil) throws {
        let root = rootURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Buffera/LiteRT", isDirectory: true)
        url = root.appendingPathComponent(role.rawValue, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Call only once the worker has exited, or when launching it failed.
    public func remove() { try? FileManager.default.removeItem(at: url) }

    /// Waiting for a killed worker must not block UI cancellation/shutdown.
    func removeAfterExit(of process: Process) {
        DispatchQueue.global(qos: .utility).async {
            if process.isRunning { process.waitUntilExit() }
            remove()
        }
    }
}
