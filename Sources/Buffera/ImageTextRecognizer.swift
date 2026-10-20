import BufferaLocalization
import BufferaCore
import Foundation
import ImageIO
import Vision

enum ImageTextRecognitionError: LocalizedError, Equatable {
    case noImages, unreadableImage, recognitionFailed

    var errorDescription: String? {
        switch self {
        case .noImages: return L10n.text("В записи нет изображения для распознавания.")
        case .unreadableImage: return L10n.text("Не удалось прочитать изображение для распознавания текста.")
        case .recognitionFailed: return L10n.text("Не удалось распознать текст на изображении.")
        }
    }
}

enum ImageTextRecognizer {
    private static let imageTypes = ["public.png", "public.tiff"]
    private static let maximumDimension = 4_096
    private static let maximumTextLength = 200_000

    // The caller excludes concealed entries and runs this synchronous work off the main queue.
    static func recognize(_ payload: ClipPayload) throws -> String {
        guard payload.items.contains(where: { item in item.contains { imageTypes.contains($0.type) } }) else {
            throw ImageTextRecognitionError.noImages
        }
        let languages: [String]
        do {
            let supported = try makeRequest(languages: []).supportedRecognitionLanguages()
            languages = ["ru-RU", "en-US"].filter(supported.contains)
        } catch {
            throw ImageTextRecognitionError.recognitionFailed
        }

        var text = ""
        var remaining = maximumTextLength
        for item in payload.items {
            guard item.contains(where: { imageTypes.contains($0.type) }) else { continue }
            let lines = try autoreleasepool {
                // PNG and TIFF within an item describe the same image, not separate pages.
                guard let image = decodeImage(item) else { throw ImageTextRecognitionError.unreadableImage }
                let request = makeRequest(languages: languages)
                do {
                    // ImageIO already applied the source orientation to the thumbnail.
                    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                } catch {
                    throw ImageTextRecognitionError.recognitionFailed
                }
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }
            for line in lines where !line.isEmpty && remaining > 0 {
                if !text.isEmpty {
                    text.append("\n")
                    remaining -= 1
                }
                let boundedLine = String(line.prefix(remaining))
                text.append(boundedLine)
                remaining -= boundedLine.count
            }
            // Continue validating remaining images even after the output cap; never report partial success.
        }
        return text
    }

    private static func makeRequest(languages: [String]) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.preferBackgroundProcessing = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        return request
    }

    private static func decodeImage(_ item: [Representation]) -> CGImage? {
        for type in imageTypes {
            for representation in item where representation.type == type {
                guard let source = CGImageSourceCreateWithData(representation.data as CFData, [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary), CGImageSourceGetStatus(source) == .statusComplete,
                    CGImageSourceGetCount(source) > 0,
                    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                        kCGImageSourceShouldCache: false
                    ] as CFDictionary),
                    CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { continue }
                return image
            }
        }
        return nil
    }
}
