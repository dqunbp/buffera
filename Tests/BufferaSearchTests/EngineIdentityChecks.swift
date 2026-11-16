import BufferaCore
import BufferaModels
import Foundation

func checkEngineIdentity(root: URL) throws {
    let store = try makeTestHistoryStore(url: root.appendingPathComponent("engine-identity.sqlite"))
    let text = "Synthetic searchable record"
    _ = try store.insert(payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]]),
        kind: .text, title: text, text: text, source: "Fixture", isConcealed: false,
        date: Date(), maxCount: 100, maxBytes: 1_000_000)
    func identity(_ ext: String) -> EmbeddingIndexIdentity {
        // Same file digest and repository isolate the backend/pipeline part of the identity.
        let descriptor = LocalModelDescriptor(role: .embedding, title: "Fixture", summary: "",
            repository: "fixture/same-model", revision: String(repeating: "a", count: 40),
            filename: "fixture.\(ext)", byteCount: 1, sha256: String(repeating: "b", count: 64),
            sourceURL: URL(string: "https://example.com/model")!, licenseURL: URL(string: "https://example.com/license")!)
        return EmbeddingIndexIdentity(fingerprint: EmbeddingConfiguration.modelKey(descriptor: descriptor), dimensions: 768)
    }
    let llama = identity("gguf")
    let liteRT = identity("litertlm")
    try require(llama != liteRT, "Engine-specific input pipelines must have different index identities")
    let vector: [Float] = [1] + Array(repeating: 0, count: 767)
    try store.configureEmbeddingIndex(llama)
    let oldJob = try store.nextPendingEmbedding()!
    try require(try store.completeEmbedding(oldJob, vectors: [vector]), "Llama vector fixture is indexed")
    try store.configureEmbeddingIndex(llama)
    try require(try store.embeddingProgress().complete == 1, "Unchanged pipeline preserves indexed vectors")
    try store.configureEmbeddingIndex(liteRT)
    try require(try store.embeddingProgress().complete == 0 && store.embeddingProgress().pending == 1,
                "Switching to LiteRT discards incompatible vectors and queues reindexing")
    try require(try !store.completeEmbedding(oldJob, vectors: [vector]), "A late llama result cannot enter the LiteRT index")
    let newJob = try store.nextPendingEmbedding()!
    try require(newJob.modelFingerprint == liteRT.fingerprint, "Reindexing uses the LiteRT runtime identity")
    try require(try store.completeEmbedding(newJob, vectors: [vector]), "LiteRT vectors can complete the replacement index")
    try store.configureEmbeddingIndex(llama)
    try require(try store.embeddingProgress().complete == 0 && store.embeddingProgress().pending == 1,
                "Switching back to llama also invalidates LiteRT vectors")
    print("PASS: backend pipeline identity, vector invalidation and stale completion rejection")
}
