import AppKit
import BufferaCore

// Uses a temporary SQLite database and a private named pasteboard, never user history or the general pasteboard.
// mkdir -p .build/copy-transform-service-checks
// swiftc -emit-library -emit-module -module-name BufferaCore -I Sources/CSQLite Sources/BufferaCore/*.swift -emit-module-path .build/copy-transform-service-checks/BufferaCore.swiftmodule -o .build/copy-transform-service-checks/libBufferaCore.dylib -module-cache-path .build/ModuleCache
// swiftc -I Sources/CSQLite -I .build/copy-transform-service-checks -L .build/copy-transform-service-checks -lBufferaCore -Xlinker -rpath -Xlinker "$PWD/.build/copy-transform-service-checks" -module-cache-path .build/ModuleCache Sources/Buffera/CopyTransformOperation.swift Sources/Buffera/CopyTransformService.swift Sources/Buffera/ClipboardService.swift Sources/Buffera/ImageTextRecognizer.swift Tests/CopyTransformServiceChecks/main.swift -o .build/copy-transform-service-checks/checks
// .build/copy-transform-service-checks/checks

var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
    checkCount += 1
    print("PASS", message)
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Buffera-transform-checks-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite"))
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

func fails(_ result: Result<String, Error>) -> Bool {
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
let hiddenID = try insert(plain("hidden fixture"), concealed: true)
check(fails(transform(hiddenID)), "fresh concealed source cannot be transformed")
check(fails(transform(Int64.max)), "missing source completes with error")

func image(_ seed: UInt8) -> ClipPayload {
    ClipPayload(items: [[Representation(type: NSPasteboard.PasteboardType.png.rawValue, data: Data([seed]))]])
}
let cachedID = try insert(image(1), kind: .image)
try storage.sync { _ = try store.completeImageText(id: cachedID, text: "Cached OCR") }
let cachedResult = try transform(cachedID, .imageText).get()
check(cachedResult == "Cached OCR" && recognized == 0, "completed OCR cache is reused without recognition")
let emptyID = try insert(image(2), kind: .image)
try storage.sync { _ = try store.completeImageText(id: emptyID, text: "") }
check(fails(transform(emptyID, .imageText)) && recognized == 0, "complete empty OCR produces an error without redundant recognition")
let pendingID = try insert(image(3), kind: .image)
let pendingResult = try transform(pendingID, .imageText).get()
check(pendingResult == "OCR fixture" && recognized == 1, "pending image uses background OCR")
let pendingProgress = try storage.sync { try store.imageTextProgress() }
check(pendingProgress.pending > 0, "preview recognition does not mutate the OCR index")

let capID = try insert(image(4), kind: .image)
try storage.sync { _ = try store.completeImageText(id: capID, text: String(repeating: "x", count: 200_000)) }
check(fails(transform(capID, .imageText)), "capped OCR is rejected instead of silently presenting an incomplete result")
let lateHidden = try insert(image(5), kind: .image)
recognition = { _ in try storage.sync { try store.conceal(id: lateHidden) }; return "must not display" }
check(fails(transform(lateHidden, .imageText)), "concealment during recognition suppresses the result")
let lateDeleted = try insert(image(6), kind: .image)
recognition = { _ in try storage.sync { try store.delete(id: lateDeleted) }; return "must not display" }
check(fails(transform(lateDeleted, .imageText)), "deletion during recognition suppresses the result")
let failingID = try insert(image(7), kind: .image)
recognition = { _ in throw ImageTextRecognitionError.recognitionFailed }
check(fails(transform(failingID, .imageText)), "recognition failure always finishes the request")

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
print("Passed \(checkCount) copy transform service checks")
