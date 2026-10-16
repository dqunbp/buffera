import AppKit

if CommandLine.arguments.contains("--smoke-test") {
    do { try runSmokeTest(); print("PASS: pasteboard multi-item round trip, capture suppression, image export, sensitive marker") }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
