import BufferaLocalization
import Foundation
import BufferaCore

enum CopyTransformOperation: Hashable {
    case text(TextTransformation)
    case imageText
    case textFile(TextFileFormat)

    enum TextFileFormat: String, CaseIterable { case txt, md }

    var title: String {
        switch self {
        case .text(let transformation): return transformation.title
        case .imageText: return L10n.text("Текст с картинки")
        case .textFile(.txt): return L10n.text("Как файл .txt")
        case .textFile(.md): return L10n.text("Как файл .md")
        }
    }

    var detail: String {
        switch self {
        case .text(let transformation): return transformation.detail
        case .imageText: return L10n.text("Распознать и скопировать текст с изображения.")
        case .textFile: return L10n.text("Скопировать полный текст как файл UTF-8 без изменения содержимого.")
        }
    }

    static func available(for clip: ClipSummary) -> [Self] {
        guard !clip.isConcealed else { return [] }
        switch clip.kind {
        case .text, .link: return TextTransformation.allCases.map(Self.text) + TextFileFormat.allCases.map(Self.textFile)
        case .image: return [.imageText]
        case .file, .other: return []
        }
    }
}
