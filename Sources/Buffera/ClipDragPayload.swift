import AppKit
import BufferaCore
import BufferaLocalization
import ImageIO
import UniformTypeIdentifiers

enum ClipDragFailure: LocalizedError {
    case unreadable, fileUnavailable, imageUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadable: return L10n.text("Не удалось подготовить содержимое для перетаскивания.")
        case .fileUnavailable: return L10n.text("Один из файлов недоступен. Возможно, он перемещён, удалён или нет доступа к нему.")
        case .imageUnavailable: return L10n.text("Не удалось подготовить файл изображения для перетаскивания.")
        }
    }
}

/// Prepared off the main thread. Item boundaries and original representations
/// survive unchanged; fallbacks are added to the same item, never as duplicates.
struct ClipDragPayload {
    let items: [[Representation]]

    static func prepare(_ payload: ClipPayload, id: Int64,
                        exports: TemporaryImageExports) throws -> ClipDragPayload {
        guard !payload.items.isEmpty, payload.items.allSatisfy({ !$0.isEmpty }) else {
            throw ClipDragFailure.unreadable
        }
        var items = payload.items
        var images: [TemporaryImageExports.Image] = []
        for index in items.indices {
            let original = items[index]
            guard original.allSatisfy({ !$0.type.isEmpty }),
                  Set(original.map(\.type)).count == original.count else { throw ClipDragFailure.unreadable }
            // Validate every file before starting; a multi-file record is never
            // silently reduced to the subset that still exists.
            if let file = original.first(where: { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }) {
                guard let value = String(data: file.data, encoding: .utf8),
                      let url = URL(string: value), url.isFileURL,
                      (try? url.checkResourceIsReachable()) == true,
                      FileManager.default.isReadableFile(atPath: url.path) else { throw ClipDragFailure.fileUnavailable }
                continue
            }
            if let image = try imageFile(original) {
                images.append(.init(data: image.0, fileExtension: image.1, itemIndex: index))
            }
            if !original.contains(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue }) {
                if let text = ClipboardText.decode(original) ?? string(.URL, in: original) {
                    items[index].append(.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8)))
                }
            }
            if !original.contains(where: { $0.type == NSPasteboard.PasteboardType.URL.rawValue }),
               let text = string(.string, in: items[index])?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               url.host != nil, !text.contains(where: \.isWhitespace) {
                items[index].append(.init(type: NSPasteboard.PasteboardType.URL.rawValue, data: Data(text.utf8)))
            }
        }
        if !images.isEmpty {
            let urls = try exports.files(images, id: id)
            for (image, url) in zip(images, urls) {
                items[image.itemIndex!].append(.init(type: NSPasteboard.PasteboardType.fileURL.rawValue,
                                                   data: Data(url.absoluteString.utf8)))
            }
        }
        return ClipDragPayload(items: items)
    }

    func pasteboardItems() throws -> [NSPasteboardItem] {
        try items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                guard item.setData(representation.data, forType: .init(representation.type)) else {
                    throw ClipDragFailure.unreadable
                }
            }
            return item
        }
    }

    private static func string(_ type: NSPasteboard.PasteboardType, in items: [Representation]) -> String? {
        items.first(where: { $0.type == type.rawValue }).flatMap { String(data: $0.data, encoding: .utf8) }
    }

    private static func imageFile(_ items: [Representation]) throws -> (Data, String)? {
        let images = items.filter { UTType($0.type)?.conforms(to: .image) == true }
        guard !images.isEmpty else { return nil }
        if let image = ClipboardService.imageData(ClipPayload(items: [items])),
           CGImageSourceCreateWithData(image.0 as CFData, nil) != nil { return image }
        // Preserve formats such as GIF/JPEG/HEIC and vector images even when
        // ImageIO cannot render them. The receiving application owns decoding.
        for image in images {
            if let ext = UTType(image.type)?.preferredFilenameExtension,
               ext.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil,
               !image.data.isEmpty {
                return (image.data, ext)
            }
        }
        throw ClipDragFailure.imageUnavailable
    }
}
