import AppKit
import BufferaCore
import WebKit

/// Manual smoke fixture: the real panel, a native rich-text editor and a local
/// browser drop target. It never reads user history or writes the clipboard.
final class DragUIDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    let panel = HistoryPanel()
    let destination = NSWindow(contentRect: NSRect(x: 660, y: 160, width: 560, height: 650),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BufferaDragUI-\(UUID().uuidString)")
    var rows: [ClipSummary] = []
    var payloads: [Int64: ClipPayload] = [:]
    var exports: TemporaryImageExports!
    let clipboardVersion = NSPasteboard.general.changeCount
    let result = NSTextField(labelWithString: "No drops yet")
    var delayPreparation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try build() } catch { fatalError(error.localizedDescription) }
    }

    private func build() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        exports = TemporaryImageExports(directory: root.appendingPathComponent("Images"))
        let file = root.appendingPathComponent("fixture.txt")
        try Data("File fixture".utf8).write(to: file)
        let folder = root.appendingPathComponent("Fixture folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 160, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        let rich = NSAttributedString(string: "Bold drag fixture", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let fixtures: [(ClipKind, String, ClipPayload)] = [
            (.text, "Bold drag fixture", .init(items: [[rep(.string, "Bold drag fixture"), .init(type: "public.rtf", data: rtf)]])),
            (.link, "https://example.com/drag-fixture", .init(items: [[rep(.string, "https://example.com/drag-fixture")]])),
            (.image, "Two images", .init(items: [[.init(type: "public.png", data: png)], [.init(type: "public.png", data: png)]])),
            (.file, "File and folder", .init(items: [[rep(.fileURL, file.absoluteString)], [rep(.fileURL, folder.absoluteString)]])),
            (.other, "Custom data", .init(items: [[rep(.init("app.example.custom"), "Custom drag fixture")]]))
        ]
        for (index, fixture) in fixtures.enumerated() {
            let id = Int64(index + 1)
            payloads[id] = fixture.2
            rows.append(.init(id: id, date: Date(), kind: fixture.0, title: fixture.1, text: fixture.1,
                              source: "Drag fixture", byteCount: fixture.2.byteCount))
        }
        panel.applyAppearance(.init(mode: .floating, columns: 1, visibleRows: 6, sidebarVisible: false))
        panel.request = { [weak self] _, _, _ in
            guard let self else { return }; self.panel.receive(self.rows, total: self.rows.count, offset: 0)
        }
        panel.requestThumbnail = { [weak self] id, completion in completion(self?.payloads[id].flatMap(ClipboardService.thumbnail)) }
        panel.requestDragPayload = { [weak self] id, completion in
            guard let self else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + (self.delayPreparation ? 2 : 0)) {
                let prepared = Result { try ClipDragPayload.prepare(self.payloads[id]!, id: id, exports: self.exports) }
                DispatchQueue.main.async { completion(prepared) }
            }
        }
        panel.onDragCompleted = { [weak self] id in
            guard let self else { return }
            let unchanged = NSPasteboard.general.changeCount == self.clipboardVersion
            self.result.stringValue = "Accepted #\(id); clipboard unchanged: \(unchanged)"
            print(self.result.stringValue); fflush(stdout)
        }
        destination.title = "Buffera drag test — local destinations"
        let host = destination.contentView!
        let button = NSButton(title: "Show history", target: self, action: #selector(showHistory))
        button.frame = NSRect(x: 16, y: 606, width: 140, height: 30); host.addSubview(button)
        let delay = NSButton(checkboxWithTitle: "Delay preparation 2s", target: self, action: #selector(toggleDelay(_:)))
        delay.frame = NSRect(x: 180, y: 606, width: 210, height: 30); host.addSubview(delay)
        result.frame = NSRect(x: 16, y: 574, width: 530, height: 24); host.addSubview(result)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 360, width: 528, height: 204))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isRichText = true
        text.string = "Native rich-text editor: drop text here.\n"
        scroll.documentView = text; host.addSubview(scroll)
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "dropResult")
        let web = WKWebView(frame: NSRect(x: 16, y: 16, width: 528, height: 330), configuration: config)
        web.loadHTMLString("""
        <style>body{font:16px system-ui;background:#edf5ff}#drop{border:3px dashed #487ac3;padding:30px}pre{white-space:pre-wrap}</style>
        <div id="drop">Local web drop area: images, files, links<input type="file" multiple></div><pre id="result">No browser drops yet</pre>
        <script>document.addEventListener('dragover',e=>{e.preventDefault();e.dataTransfer.dropEffect='copy'});
        document.addEventListener('drop',async e=>{e.preventDefault();let d=e.dataTransfer;
        let message=JSON.stringify({types:[...d.types],files:[...d.files].map(f=>({name:f.name,size:f.size,type:f.type})),text:d.getData('text/plain')});
        document.querySelector('#result').textContent=message;window.webkit.messageHandlers.dropResult.postMessage(message)});</script>
        """, baseURL: nil)
        host.addSubview(web)
        destination.makeKeyAndOrderFront(nil)
        showHistory()
    }

    @objc func showHistory() {
        panel.open()
        panel.window.setFrame(NSRect(x: 100, y: 160, width: 520, height: 650), display: true)
    }
    @objc func toggleDelay(_ sender: NSButton) { delayPreparation = sender.state == .on }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("BROWSER", message.body); fflush(stdout)
    }
    func applicationWillTerminate(_ notification: Notification) { try? FileManager.default.removeItem(at: root) }
}

func runDragUI() -> Never {
    freopen("/tmp/buffera-drag-ui.log", "w", stdout)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
    let delegate = DragUIDelegate()
    app.delegate = delegate
    app.activate(ignoringOtherApps: true)
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
}
