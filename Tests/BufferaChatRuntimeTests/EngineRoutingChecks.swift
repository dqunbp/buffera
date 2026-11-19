import BufferaModels
import CryptoKit
import Foundation

func checkEngineRouting(root: URL) async throws {
    let directory = root.appendingPathComponent("routing")
    let bundle = directory.appendingPathComponent("Fixture.app")
    let bin = bundle.appendingPathComponent("Contents/MacOS")
    let cacheRoot = directory.appendingPathComponent("caches")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let launchLog = bin.appendingPathComponent("launches.jsonl")
    for ext in ["gguf", "litertlm"] {
        let liteRT = ext == "litertlm"
        let modelRoot = directory.appendingPathComponent(ext)
        let data = Data("routing fixture".utf8)
        let descriptor = LocalModelDescriptor(role: .assistant, title: "Routing", summary: "",
            repository: "fixture/routing", revision: String(repeating: "c", count: 40), filename: "fixture.\(ext)",
            byteCount: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sourceURL: URL(string: "http://127.0.0.1/model")!, licenseURL: URL(string: "https://example.com/license")!)
        let modelURL = modelRoot.appendingPathComponent("assistant").appendingPathComponent(descriptor.revision)
            .appendingPathComponent(descriptor.filename)
        try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: modelURL)
        let receipt = try JSONSerialization.data(withJSONObject: ["assistant": ["revision": descriptor.revision,
            "sha256": descriptor.sha256, "state": "downloaded", "enabled": true]])
        let receiptURL = modelRoot.appendingPathComponent("state.json")
        try receipt.write(to: receiptURL)
        let executableName = liteRT ? "BufferaLiteRTChatWorker" : "BufferaChatWorker"
        let workerURL = bin.appendingPathComponent(executableName)
        // Only the correct executable exists; an override cannot mask engine routing.
        let source = #"""
        #!/usr/bin/python3
        import json, os, struct, sys
        if len(sys.argv) == 3:
            assert os.path.isdir(sys.argv[2])
            with open(os.path.join(sys.argv[2], 'compiled'), 'w') as f: f.write('fixture')
        with open(os.path.join(os.path.dirname(__file__), 'launches.jsonl'), 'a') as f:
            f.write(json.dumps(sys.argv) + '\n')
        while True:
            header = sys.stdin.buffer.read(4)
            if not header: break
            request = json.loads(sys.stdin.buffer.read(struct.unpack('>I', header)[0]))
            response = {'id': request['id'], 'event': 'done', 'stopReason': 'completed', 'inputTokens': 2, 'outputTokens': 0}
            body = json.dumps(response).encode()
            sys.stdout.buffer.write(struct.pack('>I', len(body)) + body)
            sys.stdout.buffer.flush()
        """#
        try source.write(to: workerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workerURL.path)
        func runtime() -> ChatRuntime {
            ChatRuntime(modelRootURL: modelRoot, bundleURL: bundle, cacheRootURL: cacheRoot,
                        idleTimeout: 30, requestTimeout: 5, descriptor: descriptor)
        }
        let first = runtime()
        let second = runtime()
        defer { first.shutdown(); second.shutdown() }
        _ = try await first.generate(messages: [ChatMessage(role: .user, content: "routing")])
        _ = try await second.generate(messages: [ChatMessage(role: .user, content: "routing")])
        let entries = try String(contentsOf: launchLog, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode([String].self, from: Data($0.utf8))
        }
        check(entries.count == 2 && entries.allSatisfy { URL(fileURLWithPath: $0[0]).lastPathComponent == executableName
              && $0[1] == modelURL.path && $0.count == (liteRT ? 3 : 2) },
              "\(ext): routes to the bundled worker with engine-specific arguments")
        let persistedReceipt = try Data(contentsOf: receiptURL)
        check(persistedReceipt == receipt, "\(ext): inference leaves the receipt unchanged")
        check(!FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("RuntimeCache").path),
              "\(ext): inference never writes a cache into the model store")
        if liteRT {
            let caches = entries.map { URL(fileURLWithPath: $0[2]) }
            check(caches[0] != caches[1] && caches.allSatisfy { $0.path.hasPrefix(cacheRoot.path + "/") },
                  "LiteRT: concurrent app/MCP consumers have isolated caches outside Models")
            first.unload()
            let removedFirst = await eventually { !FileManager.default.fileExists(atPath: caches[0].path) }
            check(removedFirst && FileManager.default.fileExists(atPath: caches[1].path),
                  "LiteRT: unloading removes only that worker's cache")
            _ = try await second.generate(messages: [ChatMessage(role: .user, content: "routing")])
            second.shutdown()
            let removedSecond = await eventually { !FileManager.default.fileExists(atPath: caches[1].path) }
            check(removedSecond, "LiteRT: shutdown cleans cache after worker exit")
            try "invalid executable".write(to: workerURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workerURL.path)
            let failedLaunch = runtime()
            await expectError("LiteRT: launch failure is returned to the caller") {
                _ = try await failedLaunch.generate(messages: [ChatMessage(role: .user, content: "routing")])
            }
            failedLaunch.shutdown()
            let removedFailedLaunch = await eventually {
                (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.appendingPathComponent("assistant").path).isEmpty) == true
            }
            check(removedFailedLaunch, "LiteRT: failed launch also removes its cache")
        } else { first.shutdown(); second.shutdown() }
        try FileManager.default.removeItem(at: workerURL)
        try FileManager.default.removeItem(at: launchLog)
    }
}
