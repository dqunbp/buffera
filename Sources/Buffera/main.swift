import AppKit

if CommandLine.arguments.contains("--features-ui-smoke-test") {
    do { try runFeatureSettingsSmokeTest(); print("PASS: feature settings, preparation controls and layout") }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--chat-ui-smoke-test") {
    do { try runHistoryChatSmokeTest(); print("PASS: history chat layout, input, sources and cancellation") }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--ocr-smoke-test") {
    do {
        try runImageTextSmokeTest()
        try runImageTextIndexerChecks()
        print("PASS: local Vision OCR and background image-text indexing")
    }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--smoke-test") {
    do { try runSmokeTest(); print("PASS: pasteboard round trip, capture suppression, image export, concealed metadata and reveal, transient policy, source bookkeeping, preview decoding") }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
