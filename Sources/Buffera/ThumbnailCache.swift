import AppKit
import BufferaCore
import os

/// Derived, disposable images. Confined to the history store's serial queue.
/// Original file URLs are never opened here, even after a cache miss or corruption.
final class ThumbnailCache {
    private let directory: URL
    private let maximumBytes: Int
    private let maximumCount: Int
    private let manager = FileManager.default
    private let logger = Logger(subsystem: "local.buffera.app", category: "thumbnail-cache")

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Buffera/Thumbnails", isDirectory: true),
         maximumBytes: Int = 64 * 1024 * 1024, maximumCount: Int = 512) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumCount = maximumCount
    }

    func thumbnail(id: Int64, payload: ClipPayload, isConcealed: Bool) -> NSImage? {
        guard !isConcealed else { remove(id: id); return nil }
        let url = location(id: id, payload: payload)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 2 * 1024 * 1024, let data = try? Data(contentsOf: url),
           let image = ClipboardService.thumbnail(ClipPayload(items: [[Representation(type: "public.png", data: data)]])) {
            return image
        }
        // Safe backfill for old history: embedded pixels only, never a file URL.
        guard let image = ClipboardService.thumbnail(payload) else { return nil }
        save(image, id: id, payload: payload, isConcealed: false)
        return image
    }

    /// Called after explicit preview or when embedded pixels are captured.
    func save(_ image: NSImage, id: Int64, payload: ClipPayload, isConcealed: Bool) {
        guard !isConcealed else { remove(id: id); return }
        guard let small = ClipboardService.thumbnail(image),
              let cgImage = small.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try png.write(to: location(id: id, payload: payload), options: .atomic)
            prune { _ in true }
        } catch {
            // A cache failure must not turn a successful history capture into an error.
            logger.error("Could not save a thumbnail cache entry")
        }
    }

    func remove(id: Int64) {
        for url in entries() where url.lastPathComponent.hasPrefix("\(id)-") { remove(url) }
    }

    /// Remove deleted/concealed records and bound disk usage, including after relaunch.
    func prune(keep: (Int64) -> Bool) {
        var retained: [(url: URL, size: Int, date: Date)] = []
        for url in entries() {
            guard let prefix = url.lastPathComponent.split(separator: "-").first,
                  let id = Int64(prefix), keep(id),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { remove(url); continue }
            retained.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        retained.sort { $0.date > $1.date }
        var bytes = 0
        for (index, entry) in retained.enumerated() {
            bytes += entry.size
            if index >= maximumCount || bytes > maximumBytes { remove(entry.url) }
        }
    }

    private func location(id: Int64, payload: ClipPayload) -> URL {
        // The fingerprint prevents stale images if a database is replaced and IDs repeat.
        directory.appendingPathComponent("\(id)-\(payload.fingerprint).png")
    }

    private func entries() -> [URL] {
        (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func remove(_ url: URL) {
        do { try manager.removeItem(at: url) }
        catch { logger.error("Could not remove a thumbnail cache entry") }
    }
}
