import Foundation

/// Ordinary history metadata derived only from stored clipboard representations.
/// Shared by new captures and explicit removal of concealment; never reads files.
public struct ClipboardMetadata {
    public let kind: ClipKind
    public let title: String
    public let text: String

    public init(payload: ClipPayload) {
        let types = Set(payload.items.flatMap { $0.map(\.type) })
        func string(_ item: [Representation], type: String) -> String? {
            item.first(where: { $0.type == type }).flatMap { String(data: $0.data, encoding: .utf8) }
        }
        let fileURLs = payload.items.compactMap { string($0, type: "public.file-url").flatMap(URL.init(string:)) }
        var text = payload.items.compactMap { string($0, type: "public.utf8-plain-text") }.joined(separator: "\n")
        if text.isEmpty, let first = payload.items.first {
            // Capture historically falls back to RTF only from the first item.
            text = ClipboardText.decode(first.filter { $0.type == "public.rtf" }) ?? ""
        }
        if !fileURLs.isEmpty {
            kind = .file
            text = fileURLs.map(\.path).joined(separator: "\n")
            title = fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        } else if types.contains("public.png") || types.contains("public.tiff") {
            kind = .image
            title = "Картинка"
        } else if !text.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            kind = ["https", "http"].contains(URL(string: trimmed)?.scheme?.lowercased() ?? "") && !trimmed.contains(where: \.isWhitespace) ? .link : .text
            title = String(trimmed.replacingOccurrences(of: "\n", with: " ").prefix(240))
        } else {
            kind = .other
            title = "Данные: " + (payload.items.first?.first?.type ?? "неизвестный формат")
        }
        self.text = String(text.prefix(200_000))
    }
}
