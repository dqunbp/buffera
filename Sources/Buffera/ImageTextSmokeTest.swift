import BufferaCore
import CoreText
import Foundation
import ImageIO
import Vision

// Synthetic fixtures only: this test neither reads nor writes the general pasteboard.
func runImageTextSmokeTest() throws {
    let languageRequest = VNRecognizeTextRequest()
    languageRequest.revision = VNRecognizeTextRequestRevision3
    languageRequest.recognitionLevel = .accurate
    let supportsRussian = try languageRequest.supportedRecognitionLanguages().contains("ru-RU")

    let english = try imageTextFixture(lines: ["Clipboard search fixture"])
    let russian = try imageTextFixture(lines: ["Буфера проверка текста"])
    let bilingual = try imageTextFixture(lines: ["Clipboard search fixture", "Буфера проверка текста"])
    let png = try imageTextFixtureData(bilingual, type: "public.png")
    let tiff = try imageTextFixtureData(bilingual, type: "public.tiff")
    func imagePayload(_ representations: [Representation]) -> ClipPayload {
        ClipPayload(items: [representations])
    }
    func checkText(_ text: String, _ context: String) throws {
        let normalized = text.lowercased()
        guard normalized.contains("clipboard"), normalized.contains("search"),
              !supportsRussian || (normalized.contains("буфера") && normalized.contains("текста")) else {
            throw HistoryError.database("Image OCR smoke test failed: \(context)")
        }
    }
    let originalPayload = imagePayload([
        Representation(type: "public.png", data: png)
    ])
    let recognized = try ImageTextRecognizer.recognize(originalPayload)
    try checkText(recognized, "English and supported Russian text")
    try imageTextSearchSmokeCheck(payload: originalPayload, text: recognized, supportsRussian: supportsRussian)

    let blank = try imageTextFixtureData(imageTextFixture(lines: []), type: "public.png")
    guard try ImageTextRecognizer.recognize(imagePayload([
        Representation(type: "public.png", data: blank)
    ])).isEmpty else { throw HistoryError.database("Image OCR smoke test failed: blank image") }

    try expectImageTextFailure(.noImages, payload: ClipPayload(items: [[
        Representation(type: "public.file-url", data: Data("file:///tmp/buffera-ocr-not-read.png".utf8)),
        Representation(type: "public.url", data: Data("https://example.invalid/not-read.png".utf8)),
        Representation(type: "public.utf8-plain-text", data: Data("Not an image".utf8))
    ]]))
    let corrupt = Representation(type: "public.png", data: Data([0, 1, 2, 3]))
    try expectImageTextFailure(.unreadableImage, payload: imagePayload([corrupt]))

    let fallback = try ImageTextRecognizer.recognize(imagePayload([
        corrupt, Representation(type: "public.tiff", data: tiff)
    ]))
    try checkText(fallback, "corrupt PNG with valid TIFF fallback")

    let alternateFormats = try ImageTextRecognizer.recognize(imagePayload([
        Representation(type: "public.tiff", data: tiff),
        Representation(type: "public.png", data: png)
    ]))
    try checkText(alternateFormats, "alternate formats")
    guard alternateFormats.lowercased().components(separatedBy: "clipboard").count == 2 else {
        throw HistoryError.database("Image OCR smoke test failed: duplicate alternate-format text")
    }

    let multipleItems = ClipPayload(items: [
        [Representation(type: "public.png", data: try imageTextFixtureData(english, type: "public.png"))],
        [Representation(type: "public.utf8-plain-text", data: Data("Ignore this item".utf8))],
        [Representation(type: "public.tiff", data: try imageTextFixtureData(russian, type: "public.tiff"))]
    ])
    let multipleText = try ImageTextRecognizer.recognize(multipleItems)
    try checkText(multipleText, "all image items")
    if supportsRussian {
        let normalized = multipleText.lowercased()
        guard let first = normalized.range(of: "clipboard"), let second = normalized.range(of: "буфера"),
              first.lowerBound < second.lowerBound else {
            throw HistoryError.database("Image OCR smoke test failed: item order")
        }
    }
    try expectImageTextFailure(.unreadableImage, payload: ClipPayload(items: [
        [Representation(type: "public.png", data: png)], [corrupt]
    ]))

    // TIFF orientation 6 rotates the stored sideways pixels back to their upright form.
    let rotated = try imageTextRotatedFixture(bilingual)
    let orientedTIFF = try imageTextFixtureData(rotated, type: "public.tiff", orientation: 6)
    try checkText(ImageTextRecognizer.recognize(imagePayload([
        Representation(type: "public.tiff", data: orientedTIFF)
    ])), "orientation metadata")

    let large = try imageTextFixture(lines: ["Clipboard search fixture"], width: 5_000, fontSize: 96)
    let largeText = try ImageTextRecognizer.recognize(imagePayload([
        Representation(type: "public.png", data: try imageTextFixtureData(large, type: "public.png"))
    ]))
    guard largeText.lowercased().contains("clipboard") else {
        throw HistoryError.database("Image OCR smoke test failed: downsampled large image")
    }
}

private func imageTextSearchSmokeCheck(payload: ClipPayload, text: String, supportsRussian: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BufferaOCRSmoke-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try autoreleasepool {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let id = try store.insert(payload: payload, kind: .image, title: "Картинка", text: "", source: "Smoke")
        var filters = [SearchFilter()]
        filters[0].query = "clipboard search"
        if supportsRussian {
            var russian = SearchFilter(); russian.query = "буфера текста"
            filters.append(russian)
        }
        for filter in filters {
            guard try store.search(filter).isEmpty else {
                throw HistoryError.database("Image OCR smoke test failed: fixture matched before indexing")
            }
        }
        guard try store.completeImageText(id: id, text: text), try store.payload(id: id) == payload else {
            throw HistoryError.database("Image OCR smoke test failed: index completion or original payload")
        }
        for filter in filters {
            let results = try store.search(filter)
            guard results.count == 1, results[0].id == id, results[0].kind == .image, results[0].text.isEmpty else {
                throw HistoryError.database("Image OCR smoke test failed: recognized text did not find original image")
            }
        }
        try store.conceal(id: id)
        for filter in filters {
            guard try store.search(filter).isEmpty else {
                throw HistoryError.database("Image OCR smoke test failed: concealed image remained searchable")
            }
        }
        guard try store.payload(id: id) == payload else {
            throw HistoryError.database("Image OCR smoke test failed: concealment changed original payload")
        }
    }
}

private func expectImageTextFailure(_ expected: ImageTextRecognitionError, payload: ClipPayload) throws {
    do {
        _ = try ImageTextRecognizer.recognize(payload)
    } catch let error as ImageTextRecognitionError where error == expected {
        return
    }
    throw HistoryError.database("Image OCR smoke test failed: expected bounded failure")
}

private func imageTextFixture(lines: [String], width: Int = 1_400, fontSize: CGFloat = 64) throws -> CGImage {
    let height = 360
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw HistoryError.database("Could not create image OCR fixture")
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    for (index, text) in lines.enumerated() {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 48, y: height - 110 - index * 110)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    guard let image = context.makeImage() else { throw HistoryError.database("Could not render image OCR fixture") }
    return image
}

private func imageTextFixtureData(_ image: CGImage, type: String, orientation: Int = 1) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
        throw HistoryError.database("Could not create image OCR fixture encoder")
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw HistoryError.database("Could not encode image OCR fixture") }
    return data as Data
}

private func imageTextRotatedFixture(_ image: CGImage) throws -> CGImage {
    guard let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw HistoryError.database("Could not create rotated image OCR fixture")
    }
    context.translateBy(x: CGFloat(image.height), y: 0)
    context.rotate(by: .pi / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = context.makeImage() else { throw HistoryError.database("Could not rotate image OCR fixture") }
    return result
}
