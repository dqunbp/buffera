import AppKit

/// Shared text decoding for clipboard history consumers. Representations are alternatives of one item.
public enum ClipboardText {
    public static func decode(_ representations: [Representation]) -> String? {
        if let text = representations.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue })
            .flatMap({ String(data: $0.data, encoding: .utf8) }), !text.isEmpty { return text }
        guard let rtf = representations.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }),
              let text = try? NSAttributedString(data: rtf.data,
                  options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string,
              !text.isEmpty else { return nil }
        return text
    }
}
