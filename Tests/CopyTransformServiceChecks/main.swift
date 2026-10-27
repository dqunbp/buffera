import AppKit
import BufferaCore

// Uses a temporary SQLite database and a private named pasteboard, never user history or the general pasteboard.
// Run with: zsh scripts/check-copy-transform.sh

var checkCount = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        if try !condition() { fatalError(message) }
    } catch { fatalError("\(message): \(error)") }
    checkCount += 1
    print("PASS", message)
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Buffera-transform-checks-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite"),
                             secretCipher: SecretPayloadCipher { _, _ in Data(repeating: 0x42, count: 32) })
let storage = DispatchQueue(label: "checks.history")
var recognized = 0
var recognition: (ClipPayload) throws -> String = { _ in "OCR fixture" }
let service = CopyTransformService(store: store, storageQueue: storage) { payload in
    recognized += 1
    return try recognition(payload)
}

func plain(_ text: String) -> ClipPayload {
    ClipPayload(items: [[Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]])
}

func insert(_ payload: ClipPayload, kind: ClipKind = .text, concealed: Bool = false) throws -> Int64 {
    try storage.sync {
        try store.insert(payload: payload, kind: kind, title: "Fixture", text: "truncated summary", source: "Checks",
                         isConcealed: concealed, date: Date(timeIntervalSince1970: 100), maxCount: 100)
    }
}

func transform(_ id: Int64, _ operation: CopyTransformOperation = .text(.plainText)) -> Result<String, Error> {
    var value: Result<String, Error>?
    service.transform(id: id, operation: operation) { result in
        check(Thread.isMainThread, "transform completion uses the main thread")
        check(value == nil, "transform completes once")
        value = result
    }
    let deadline = Date(timeIntervalSinceNow: 5)
    while value == nil, Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    guard let value else { fatalError("Transform callback did not arrive") }
    return value
}

func operations(_ id: Int64, mode: RunLoop.Mode = .default) -> Result<[CopyTransformOperation], Error> {
    var value: Result<[CopyTransformOperation], Error>?
    service.operations(id: id) { result in
        check(Thread.isMainThread, "operations completion uses the main thread")
        check(value == nil, "operations completes once")
        value = result
    }
    let deadline = Date(timeIntervalSinceNow: 5)
    while value == nil, Date() < deadline {
        _ = RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.01))
    }
    guard let value else { fatalError("Operations callback did not arrive") }
    return value
}

func fails<T>(_ result: Result<T, Error>) -> Bool {
    if case .failure = result { return true }
    return false
}

let original = plain(String(repeating: "a", count: 220_000) + "tail\n")
let longID = try insert(original)
let longResult = try transform(longID).get()
check(longResult == String(repeating: "a", count: 220_000) + "tail\n", "plain copy reads the full payload beyond summary limits")
let unchanged = try storage.sync { (try store.payload(id: longID), try store.summary(id: longID)) }
check(unchanged.0 == original && unchanged.1.date == Date(timeIntervalSince1970: 100), "preview preserves source payload and capture date")

let rtfText = "Оформленный текст\nSecond line"
let attributed = NSAttributedString(string: rtfText, attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
let rtfID = try insert(ClipPayload(items: [[Representation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf)]]))
let rtfResult = try transform(rtfID).get()
check(rtfResult == rtfText, "RTF-only payload produces complete plain text")
let fallbackPayload = ClipPayload(items: [[Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data()),
                                         Representation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf)]])
let fallbackID = try insert(fallbackPayload)
let fallbackResult = try transform(fallbackID).get()
check(fallbackResult == rtfText, "empty plain representation falls back to readable RTF")
check(ClipboardService.revealedText(fallbackPayload) == rtfText, "reveal and transform share the same text decoding")

let multi = ClipPayload(items: plain("first").items + [[Representation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf)]])
let multiID = try insert(multi)
let multiResult = try transform(multiID).get()
check(multiResult == "first\n" + rtfText, "all text items are retained in order")
let partialID = try insert(ClipPayload(items: plain("first").items + [[Representation(type: "fixture.unreadable", data: Data([1]))]]))
check(fails(transform(partialID)), "unreadable item fails instead of silently returning partial text")
let blankID = try insert(plain(" \n\t"))
let blankResult = try transform(blankID).get()
check(blankResult == " \n\t", "whitespace-only plain text is preserved exactly")
let emptyTextID = try insert(plain(""))
check(fails(transform(emptyTextID)), "empty input has an explicit error")
let badJSON = try insert(plain("{not json}"))
check(fails(transform(badJSON, .text(.formatJSON))), "transformation errors reach the caller")
let ordinaryID = try insert(plain("Обычный текст"))
check(try operations(ordinaryID).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "ordinary text offers plain copy and both file formats")
check(try operations(badJSON).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "invalid JSON is omitted from the menu")
let compactJSON = try insert(plain("{\"value\":1}"))
check(try operations(compactJSON).get() == [.text(.plainText), .text(.formatJSON)] + [.textFile(.txt), .textFile(.md)], "valid compact JSON offers formatting")
let formattedJSON = try insert(plain("{\n  \"value\": 1\n}"))
check(!(try operations(formattedJSON).get()).contains(.text(.formatJSON)), "already formatted JSON does not offer an unchanged result")
let linesID = try insert(plain("Первая строка\nВторая строка"))
check(try operations(linesID).get() == [.text(.plainText), .text(.unwrapLines)] + [.textFile(.txt), .textFile(.md)], "different lines offer unwrapping without deduplication")
let crlfLines = try insert(plain("Первая строка\r\nВторая строка"))
check(try operations(crlfLines).get() == [.text(.plainText), .text(.unwrapLines)] + [.textFile(.txt), .textFile(.md)], "CRLF normalization without duplicates does not offer deduplication")
let paragraphs = try insert(plain("  Первый абзац \r\n\r\n Второй абзац  "))
check(try operations(paragraphs).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "paragraphs without adjacent text lines do not offer unwrapping")
let paddedLine = try insert(plain("  Одна строка  "))
check(try operations(paddedLine).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "trimming a single line does not offer unwrapping")
let blankLines = try insert(plain(" \r\n \r\n\t\r\n\t"))
check(try operations(blankLines).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "repeated blank lines do not offer deduplication or unwrapping")
let duplicatesID = try insert(plain("Повтор\nПовтор"))
check(try operations(duplicatesID).get() == [.text(.plainText), .text(.unwrapLines), .text(.removeDuplicateLines)] + [.textFile(.txt), .textFile(.md)], "duplicate lines offer both applicable operations")
let unicodeID = try insert(plain("\u{00e9}\ne\u{0301}"))
check(!(try operations(unicodeID).get()).contains(.text(.removeDuplicateLines)), "canonically equal but byte-distinct lines do not offer deduplication")
let cleanURL = try insert(plain("https://example.com/?page=2"), kind: .link)
check(try operations(cleanURL).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "clean URL omits tracking cleanup")
let trackedURL = try insert(plain("https://example.com/?page=2&utm_source=checks"), kind: .link)
check(try operations(trackedURL).get() == [.text(.plainText), .text(.removeTrackingParameters)] + [.textFile(.txt), .textFile(.md)], "URL with removable trackers offers cleanup")
let signedURL = try insert(plain("https://example.com/?utm_source=checks&sig=fixture"), kind: .link)
check(try operations(signedURL).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "signed URL omits unsafe tracking cleanup")
let deepJSON = try insert(plain(String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129)))
check(try operations(deepJSON).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "JSON beyond supported depth omits formatting")
let longDuplicate = try insert(plain(String(repeating: "x", count: 220_000) + "\ntail\ntail"))
check((try operations(longDuplicate).get()).contains(.text(.removeDuplicateLines)), "applicability reads duplicate lines beyond the summary limit")
let longJSON = try insert(plain("{\"text\":\"" + String(repeating: "x", count: 220_000) + "\"}"))
check((try operations(longJSON).get()).contains(.text(.formatJSON)), "applicability parses full JSON beyond the summary limit")
let hugeID = try insert(plain(String(repeating: "x", count: 2 * 1_024 * 1_024 + 1) + "\nrepeat\nrepeat"))
check(try operations(hugeID).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "over-limit text keeps plain copy and omits bounded transformations")
check((try operations(rtfID).get()).contains(.text(.plainText)), "RTF-only applicability uses the shared full text decoder")
check(fails(operations(partialID)), "unreadable item prevents offering a partial text copy")
check(fails(operations(emptyTextID)), "empty source does not advertise plain copy")
let hiddenID = try insert(plain("hidden fixture"), concealed: true)
check(fails(transform(hiddenID)), "fresh concealed source cannot be transformed")
check(fails(transform(Int64.max)), "missing source completes with error")
check(fails(operations(hiddenID)), "fresh concealed source has no applicable menu")
check(fails(operations(Int64.max)), "missing source fails menu applicability")
check(try operations(ordinaryID, mode: .eventTracking).get() == [.text(.plainText)] + [.textFile(.txt), .textFile(.md)], "menu availability arrives during native menu tracking")
check(fails(operations(Int64.max, mode: .eventTracking)), "menu errors arrive during native menu tracking")
let fileID = try insert(plain("fixture file"), kind: .file)
check(try operations(fileID).get().isEmpty, "unsupported source has no transformations")

func image(_ seed: UInt8) -> ClipPayload {
    ClipPayload(items: [[Representation(type: NSPasteboard.PasteboardType.png.rawValue, data: Data([seed]))]])
}
let cachedID = try insert(image(1), kind: .image)
try storage.sync { _ = try store.completeImageText(id: cachedID, text: "Cached OCR") }
let cachedResult = try transform(cachedID, .imageText).get()
check(cachedResult == "Cached OCR" && recognized == 0, "completed OCR cache is reused without recognition")
check(try operations(cachedID).get() == [.imageText], "complete OCR text is available in the menu")
let emptyID = try insert(image(2), kind: .image)
try storage.sync { _ = try store.completeImageText(id: emptyID, text: "") }
check(fails(transform(emptyID, .imageText)) && recognized == 0, "complete empty OCR produces an error without redundant recognition")
check(try operations(emptyID).get().isEmpty, "complete empty OCR omits image text")
let whitespaceImageID = try insert(image(8), kind: .image)
try storage.sync { _ = try store.completeImageText(id: whitespaceImageID, text: " \n\t") }
check(try operations(whitespaceImageID).get().isEmpty, "complete whitespace OCR omits image text")
let pendingID = try insert(image(3), kind: .image)
check(try operations(pendingID).get() == [.imageText], "pending OCR offers image text without running recognition")
check(recognized == 0, "opening image menus never starts OCR")
let pendingResult = try transform(pendingID, .imageText).get()
check(pendingResult == "OCR fixture" && recognized == 1, "pending image uses background OCR")
let pendingProgress = try storage.sync { try store.imageTextProgress() }
check(pendingProgress.pending > 0, "preview recognition does not mutate the OCR index")

let capID = try insert(image(4), kind: .image)
try storage.sync { _ = try store.completeImageText(id: capID, text: String(repeating: "x", count: 200_000)) }
check(fails(transform(capID, .imageText)), "capped OCR is rejected instead of silently presenting an incomplete result")
check(try operations(capID).get().isEmpty, "capped OCR is omitted from the menu")
let lateHidden = try insert(image(5), kind: .image)
recognition = { _ in try storage.sync { try store.conceal(id: lateHidden) }; return "must not display" }
check(fails(transform(lateHidden, .imageText)), "concealment during recognition suppresses the result")
let lateDeleted = try insert(image(6), kind: .image)
recognition = { _ in try storage.sync { try store.delete(id: lateDeleted) }; return "must not display" }
check(fails(transform(lateDeleted, .imageText)), "deletion during recognition suppresses the result")
let failingID = try insert(image(7), kind: .image)
recognition = { _ in throw ImageTextRecognitionError.recognitionFailed }
check(fails(transform(failingID, .imageText)), "recognition failure always finishes the request")

// Hold the shared worker after storage reads, so source mutations happen before applicability completes.
let blockedImage = try insert(image(9), kind: .image)
let menuHidden = try insert(plain("hide while menu loads"))
let menuDeleted = try insert(plain("delete while menu loads"))
let workerEntered = DispatchSemaphore(value: 0), releaseWorker = DispatchSemaphore(value: 0)
recognition = { _ in workerEntered.signal(); releaseWorker.wait(); return "Held OCR" }
var blockedFinished = false
service.transform(id: blockedImage, operation: .imageText) { _ in blockedFinished = true }
check(workerEntered.wait(timeout: .now() + 5) == .success, "worker gate starts for concurrent applicability checks")
var hiddenMenu: Result<[CopyTransformOperation], Error>?, deletedMenu: Result<[CopyTransformOperation], Error>?
service.operations(id: menuHidden) { result in
    check(Thread.isMainThread && hiddenMenu == nil, "late concealed menu completes once on the main thread")
    hiddenMenu = result
}
service.operations(id: menuDeleted) { result in
    check(Thread.isMainThread && deletedMenu == nil, "late deleted menu completes once on the main thread")
    deletedMenu = result
}
try storage.sync { try store.conceal(id: menuHidden); try store.delete(id: menuDeleted) }
releaseWorker.signal()
let menuDeadline = Date(timeIntervalSinceNow: 5)
while (!blockedFinished || hiddenMenu == nil || deletedMenu == nil), Date() < menuDeadline {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}
check(blockedFinished, "held worker finishes after release")
guard let hiddenMenu, let deletedMenu else { fatalError("Late applicability callbacks did not arrive") }
check(fails(hiddenMenu), "concealment during applicability suppresses available actions")
check(fails(deletedMenu), "deletion during applicability suppresses available actions")

let pasteboard = NSPasteboard(name: .init("Buffera-copy-transform-checks-\(UUID().uuidString)"))
defer { pasteboard.releaseGlobally() }
let clipboard = ClipboardService(pasteboard: pasteboard, frontmostApplicationName: { "Checks" })
var captures = 0
clipboard.onCapture = { _ in captures += 1 }
let exactOutput = "  exact\ntext\n"
try clipboard.restore(plain(exactOutput))
clipboard.poll()
check(pasteboard.string(forType: .string) == exactOutput, "transformed output is written exactly")
check(pasteboard.pasteboardItems?.first?.types == [.string], "transformed clipboard contains only plain text")
check(captures == 0, "internal transformed restore is not captured as a new history entry")
let exports = TemporaryImageExports(directory: folder.appendingPathComponent("exports"))
let fileText = "# Заголовок 📝\r\n\r\n  **text**\t\n" + String(repeating: "tail", count: 60_000)
let exportID = try insert(plain(fileText))
for format in CopyTransformOperation.TextFileFormat.allCases {
    let operation = CopyTransformOperation.textFile(format)
    let text = try transform(exportID, operation).get()
    let payload = try CopyTransformService.clipboardPayload(text: text, operation: operation, id: exportID, exports: exports)
    try clipboard.restore(payload)
    clipboard.poll()
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    check(urls?.count == 1, "file export is readable as a file URL by pasteboard consumers")
    let url = urls!.first!
    check(url.lastPathComponent == "Заголовок 📝.\(format.rawValue)", "export uses the cleaned first nonempty line")
    check(try Data(contentsOf: url) == Data(fileText.utf8), "export preserves full UTF-8 bytes, whitespace and Markdown")
    check(pasteboard.string(forType: .string) == nil, "file copy does not fall back to inline text")
    check(captures == 0, "file copy is not recaptured")
    check(fails(transform(hiddenID, operation)), "concealed text cannot be exported")
    check(fails(transform(cachedID, operation)), "image cannot invoke text file export")
    check(fails(transform(emptyTextID, operation)), "empty file export reports an error")
}
let blockedDirectory = folder.appendingPathComponent("not-a-directory")
try Data([1]).write(to: blockedDirectory)
let previousChange = pasteboard.changeCount
let failedExport = Result { try CopyTransformService.clipboardPayload(text: "test", operation: .textFile(.txt),
    id: exportID, exports: TemporaryImageExports(directory: blockedDirectory)) }
check(fails(failedExport) && pasteboard.changeCount == previousChange, "file preparation failure leaves clipboard untouched")
let namingSuite = "Buffera.NamingChecks.\(UUID().uuidString)"
let namingDefaults = UserDefaults(suiteName: namingSuite)!
defer { namingDefaults.removePersistentDomain(forName: namingSuite) }
check(TextFileNaming.load(from: namingDefaults) == .firstLine, "fresh naming preference defaults to first line")
for mode in TextFileNaming.allCases {
    namingDefaults.set(mode.rawValue, forKey: TextFileNaming.preferenceKey)
    check(TextFileNaming.load(from: namingDefaults) == mode, "naming preference persists")
}
namingDefaults.set("invalid", forKey: TextFileNaming.preferenceKey)
check(TextFileNaming.load(from: namingDefaults) == .firstLine, "unknown naming preference falls back safely")
let fixedDate = Date(timeIntervalSince1970: 0)
let utc = TimeZone(secondsFromGMT: 0)!
let dateName = TextFileNaming.dateTime.basename(for: "ignored", date: fixedDate, timeZone: utc)
check(dateName.hasSuffix("-1970-01-01-00-00-00"), "date name uses deterministic Gregorian date and supplied timezone")
check(TextFileNaming.firstLine.basename(for: " \r\n\t\n##  План / недели: тест?\nsecond") == "План недели тест", "naming skips blank lines, Markdown heading and unsafe characters")
for input in ["", " \n\t", "...", "/\\:*?<>|", "### "] {
    check(TextFileNaming.firstLine.basename(for: input, date: fixedDate, timeZone: utc) == dateName,
          "unusable names fall back to copy time")
}
for input in [String(repeating: "я", count: 200), String(repeating: "👨‍👩‍👧‍👦", count: 200)] {
    let name = TextFileNaming.firstLine.basename(for: input)
    check(!name.isEmpty && name.count <= 60 && name.utf8.count <= 180, "long Unicode filenames fit character and byte bounds")
}
let datedPayload = try CopyTransformService.clipboardPayload(text: fileText, operation: .textFile(.txt),
    id: exportID, exports: exports, naming: .dateTime, date: fixedDate)
let datedURL = URL(string: String(data: datedPayload.items[0][0].data, encoding: .utf8)!)!
check(datedURL.deletingPathExtension().lastPathComponent == TextFileNaming.dateTime.basename(for: fileText, date: fixedDate),
      "date mode reaches the actual exported filename")
check(try Data(contentsOf: datedURL) == Data(fileText.utf8), "changing the filename preserves file contents")
print("Passed \(checkCount) copy transform service checks")
