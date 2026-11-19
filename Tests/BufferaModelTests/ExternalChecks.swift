import BufferaModels
import Foundation

func runExternalChecks(descriptor: LocalModelDescriptor, payload: Data, root: URL) throws {
    let external = root.appendingPathComponent("original.gguf")
    try payload.write(to: external)
    let store = root.appendingPathComponent("store")
    let manager = try LocalModelManager(rootURL: store, descriptors: [descriptor])
    defer { manager.shutdown() }
    func select(_ url: URL) -> Bool {
        var result: Result<Void, Error>?
        manager.selectExternal(url, for: .embedding) { result = $0 }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if case .success? = result { return true }
        return false
    }
    check(select(external), "external model verifies without copying")
    check(manager.modelURL(for: .embedding) == external, "external URL is the original file")
    check(!manager.snapshots[0].isEnabled, "selection does not silently enable inference")
    check(!FileManager.default.fileExists(atPath: store.appendingPathComponent("embedding").path),
          "selection creates no owned model directory")
    manager.setEnabled(true, for: .embedding)
    check(waitFor(manager) { $0.isReadyForUse }, "external model can be enabled")
    let access = LocalModelReadAccess(rootURL: store, descriptor: descriptor)
    check((try? access.enabledEmbedding().fileURL) == external, "read-only consumers use the external selection")
    // A metadata-only change revokes receipt access until successful explicit verification.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                         ofItemAtPath: external.path)
    check((try? access.enabledEmbedding()) == nil, "metadata change revokes the old receipt")
    var verification: Result<URL, Error>?
    manager.verifyInstalledModel(for: .embedding) { verification = $0 }
    let verificationDeadline = Date().addingTimeInterval(10)
    while verification == nil && Date() < verificationDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check((try? verification?.get()) != nil, "metadata-only change passes explicit verification")
    check((try? access.enabledEmbedding().fileURL) == external,
          "successful verification persists identity for independent GUI and MCP readers")
    let linkedRoot = root.appendingPathComponent("linked-store")
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: store)
    let linkedAccess = LocalModelReadAccess(rootURL: linkedRoot, descriptor: descriptor)
    check((try? linkedAccess.enabledEmbedding()) == nil, "external receipts do not bypass model-root symlink checks")
    let bad = root.appendingPathComponent("bad.gguf")
    try Data(repeating: 0, count: payload.count).write(to: bad)
    check(!select(bad), "wrong checksum is rejected")
    check(manager.modelURL(for: .embedding) == external && manager.snapshots[0].isEnabled,
          "failed selection preserves the working model")
    let owned = store.appendingPathComponent("embedding").appendingPathComponent(descriptor.revision)
        .appendingPathComponent(descriptor.filename)
    try FileManager.default.createDirectory(at: owned.deletingLastPathComponent(), withIntermediateDirectories: true)
    try payload.write(to: owned)
    manager.useDefault(for: .embedding)
    check(waitFor(manager) { $0.externalURL == nil && !$0.isEnabled }, "returning to default disables the feature")
    check((try? Data(contentsOf: owned)) == payload, "switching back retains previously owned weights")
    check((try? Data(contentsOf: external)) == payload, "switching back retains external weights")
    check(select(external), "external file can be selected again")
    manager.setEnabled(true, for: .embedding)
    check(waitFor(manager) { $0.isReadyForUse }, "reselected file can be enabled")
    manager.shutdown()
    let reopened = try LocalModelManager(rootURL: store, descriptors: [descriptor])
    check(waitFor(reopened) { $0.isReadyForUse }, "external selection survives restart and verifies")
    reopened.shutdown()
    var changed = payload
    changed[0] ^= 0xff
    try changed.write(to: external)
    check((try? access.enabledEmbedding()) == nil, "same-size replacement immediately revokes external availability")
    let corrupted = try LocalModelManager(rootURL: store, descriptors: [descriptor])
    check(waitFor(corrupted) { $0.state == .failed }, "restart rejects changed external weights")
    check((try? Data(contentsOf: external)) == changed, "failed verification never deletes external weights")
    corrupted.remove(.embedding)
    check(waitFor(corrupted) { $0.externalURL == nil }, "remove disconnects the external selection")
    check((try? Data(contentsOf: external)) == changed, "disconnect preserves the external file")
    corrupted.shutdown()
    try payload.write(to: external)
    let reset = try LocalModelManager(rootURL: store, descriptors: [descriptor])
    reset.useDefault(for: .embedding)
    check(waitFor(reset) { $0.externalURL == nil && !$0.isEnabled }, "default selection remains off and uses llama")
    reset.shutdown()

    let failureStore = root.appendingPathComponent("failed-receipt")
    let failureManager = try LocalModelManager(rootURL: failureStore, descriptors: [descriptor])
    var failureSelection: Result<Void, Error>?
    failureManager.selectExternal(external, for: .embedding) { failureSelection = $0 }
    let selectionDeadline = Date().addingTimeInterval(10)
    while failureSelection == nil && Date() < selectionDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try failureSelection?.get()
    failureManager.setEnabled(true, for: .embedding)
    check(waitFor(failureManager) { $0.isReadyForUse }, "receipt failure fixture is available")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                         ofItemAtPath: external.path)
    let blockedReceipt = failureStore.appendingPathComponent("state.json")
    try FileManager.default.removeItem(at: blockedReceipt)
    try FileManager.default.createDirectory(at: blockedReceipt, withIntermediateDirectories: true)
    // A nonempty directory cannot be replaced by an atomic receipt write.
    try Data([1]).write(to: blockedReceipt.appendingPathComponent("blocker"))
    var failedVerification: Result<URL, Error>?
    failureManager.verifyInstalledModel(for: .embedding) { failedVerification = $0 }
    let failureDeadline = Date().addingTimeInterval(10)
    while failedVerification == nil && Date() < failureDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    if case .failure? = failedVerification {
        check(true, "receipt write failure never reports verification success")
    } else { check(false, "receipt write failure never reports verification success") }
    check(failureManager.snapshots[0].state == .failed, "receipt write failure revokes availability")
    check((try? Data(contentsOf: external)) == payload, "receipt failure preserves external weights")
    failureManager.shutdown()

    let manifestRoot = root.appendingPathComponent("foresight")
    try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
    let pinned = ExternalModels.supported.first { $0.engine == .liteRT && $0.role == .embedding }!
    let candidate = manifestRoot.appendingPathComponent("test.litertlm")
    FileManager.default.createFile(atPath: candidate.path, contents: Data())
    let file = try FileHandle(forWritingTo: candidate)
    try file.truncate(atOffset: UInt64(pinned.byteCount)) // Sparse fixture; no weights/download.
    try file.close()
    func manifest(state: String, path: String, schema: Int = 1) throws {
        let json: [String: Any] = ["schemaVersion": schema, "models": ["model": [
            "physicalState": state, "storage": ["canonicalAbsolutePath": path, "expectedSizeBytes": pinned.byteCount]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: manifestRoot.appendingPathComponent(".manifest.json"))
    }
    try manifest(state: "ready", path: candidate.path)
    check(ExternalModels.discover(in: manifestRoot).count == 1, "discovery reads a ready model without trusting type IDs")
    try manifest(state: "missing", path: candidate.path)
    check(ExternalModels.discover(in: manifestRoot).isEmpty, "full-sized incomplete downloads are excluded")
    try manifest(state: "ready", path: candidate.path, schema: 2)
    check(ExternalModels.discover(in: manifestRoot).isEmpty, "unknown manifest schemas fail closed")
    try manifest(state: "ready", path: root.appendingPathComponent("outside.litertlm").path)
    check(ExternalModels.discover(in: manifestRoot).isEmpty, "manifest cannot select files outside its store")
    let cache = root.appendingPathComponent("hf-cache")
    let repo = cache.appendingPathComponent("models--test--model")
    let snapshot = repo.appendingPathComponent("snapshots/revision")
    let blobs = repo.appendingPathComponent("blobs")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    let gguf = ExternalModels.supported.first { $0.engine == .llama && $0.role == .embedding }!
    let blob = blobs.appendingPathComponent("hash")
    FileManager.default.createFile(atPath: blob.path, contents: nil)
    let blobFile = try FileHandle(forWritingTo: blob)
    try blobFile.truncate(atOffset: UInt64(gguf.byteCount))
    try blobFile.close()
    try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("model.gguf"), withDestinationURL: blob)
    try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("duplicate.gguf"), withDestinationURL: blob)
    try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("broken.gguf"), withDestinationURL: blobs.appendingPathComponent("missing"))
    try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("outside.litertlm"), withDestinationURL: candidate)
    try Data([0]).write(to: snapshot.appendingPathComponent("incomplete.gguf"))
    let discovered = ExternalModels.discoverHuggingFace(in: cache)
    check(discovered.count == 1 && discovered.first?.url == blob && discovered.first?.source == .huggingFace,
          "HF discovery resolves and deduplicates snapshot links, rejects missing/outside/incomplete files")
    check(discovered.first?.descriptor.role == .embedding, "HF discovery identifies the model role")
    try FileManager.default.removeItem(at: blob)
    check(ExternalModels.discoverHuggingFace(in: cache).isEmpty, "HF rescan removes vanished blob")
    check(ExternalModels.huggingFaceRoot(environment: [:], home: root) == root.appendingPathComponent(".cache/huggingface/hub"), "HF default cache path")
    check(ExternalModels.huggingFaceRoot(environment: ["HF_HOME": "/custom", "HF_HUB_CACHE": "/override"], home: root).path == "/override", "HF_HUB_CACHE takes precedence")
    check(ExternalModels.huggingFaceRoot(environment: ["HF_HOME": "/custom"], home: root).path == "/custom/hub", "HF_HOME supported")
    check(ExternalModels.huggingFaceRoot(environment: ["XDG_CACHE_HOME": "/xdg"], home: root).path == "/xdg/huggingface/hub", "XDG cache supported")

}
