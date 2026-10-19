import Foundation
import BufferaCore

enum CopyTransformOperation: Hashable {
    case text(TextTransformation)
    case imageText

    var title: String {
        switch self {
        case .text(let transformation): return transformation.title
        case .imageText: return "Текст с картинки"
        }
    }

    var detail: String {
        switch self {
        case .text(let transformation): return transformation.detail
        case .imageText: return "Распознать и скопировать текст с изображения."
        }
    }

    static func available(for clip: ClipSummary) -> [Self] {
        guard !clip.isConcealed else { return [] }
        switch clip.kind {
        case .text, .link: return TextTransformation.allCases.map(Self.text)
        case .image: return [.imageText]
        case .file, .other: return []
        }
    }
}
