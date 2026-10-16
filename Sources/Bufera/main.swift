import AppKit

if CommandLine.arguments.contains("--smoke-test") {
    do { try runSmokeTest(); print("PASS: pasteboard round trip, capture suppression, image export, concealed metadata and reveal, transient policy, source bookkeeping, preview decoding") }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
