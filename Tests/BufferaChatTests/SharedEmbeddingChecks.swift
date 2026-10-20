import BufferaChat
import BufferaModels
import BufferaSearch
import CryptoKit
import Foundation

/// One process is shared by independent clients; only its owner may tear it down.
func runSharedEmbeddingChecks(root: URL) async throws {
    let models = root.appendingPathComponent("shared-model-fixture")
    let bytes = Data("shared embedding fixture".utf8)
    let descriptor = LocalModelDescriptor(
        role: .embedding, title: "Fixture", summary: "", repository: "fixture/embedding",
        revision: String(repeating: "c", count: 40), filename: "fixture.gguf", byteCount: Int64(bytes.count),
        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        sourceURL: URL(string: "http://127.0.0.1/fixture")!,
        licenseURL: URL(string: "https://example.com/license")!
    )
    let directory = models.appendingPathComponent("embedding").appendingPathComponent(descriptor.revision)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bytes.write(to: directory.appendingPathComponent(descriptor.filename))
    let receipt: [String: Any] = ["embedding": [
        "revision": descriptor.revision, "sha256": descriptor.sha256, "state": "downloaded", "enabled": true
    ]]
    try JSONSerialization.data(withJSONObject: receipt).write(to: models.appendingPathComponent("state.json"))
    let executable = models.appendingPathComponent("worker.py")
    let script = #"""
#!/usr/bin/python3
import json, struct, sys
while True:
    header = sys.stdin.buffer.read(4)
    if not header: break
    request = json.loads(sys.stdin.buffer.read(struct.unpack('>I', header)[0]))
    result = {'id':request['id'],'outputs':[{'vectors':[[1.0]+[0.0]*767],'truncated':False}
                                         for _ in request['texts']]}
    body = json.dumps(result).encode()
    sys.stdout.buffer.write(struct.pack('>I',len(body))+body); sys.stdout.buffer.flush()
"""#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let shared = EmbeddingRuntime(modelRootURL: models, executableURL: executable, descriptor: descriptor)
    defer { shared.shutdown() }
    _ = try await shared.embed(["warm"], kind: .query)
    let search = HybridSearchService(modelRootURL: models, embeddingRuntime: shared)
    await search.unload()
    search.shutdown()
    try require(shared.isRunning, "Resetting or shutting down a search client preserves shared model memory")
    let chat = ChatSession(databaseURL: root.appendingPathComponent("history.sqlite"),
                           modelRootURL: models, embeddingRuntime: shared)
    await chat.unload().value
    await chat.reset()
    chat.shutdown()
    try require(shared.isRunning, "Closing, resetting and shutting down chat preserve the shared embedding worker")
    let result = try await shared.embed(["still available to history"], kind: .query)
    try require(result.count == 1, "Other consumers can still search after chat closes")
    shared.unload()
    try require(!shared.isRunning, "The application owner can explicitly release shared weights")
}
