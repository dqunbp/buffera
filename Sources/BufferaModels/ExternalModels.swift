import Foundation
import BufferaLocalization

/// Only tested weight variants are selectable. Names and manifest type IDs are
/// discovery hints; the full digest is verified before a selection is committed.
public enum ExternalModels {
    public static let supported: [LocalModelDescriptor] = LocalModelCatalog.models + [
        liteRT(.embedding, title: "EmbeddingGemma 2", size: 474_120_192,
               hash: "e53f38d71e58996659a926d1aece11f6b182b83ff7f34ae9c986405909c7b1fe"),
        liteRT(.assistant, title: "Gemma 4 E4B", size: 3_659_530_240,
               hash: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0"),
        liteRT(.assistant, title: "Gemma 4 12B", size: 6_883_278_368,
               hash: "ddfeab9430185ed153d45644fd8cc103491bbd667d7abddc8486416d706844a5")
    ]

    private static func liteRT(_ role: ModelRole, title: String, size: Int64,
                               hash: String) -> LocalModelDescriptor {
        LocalModelDescriptor(role: role, title: title, summary: "LiteRT-LM",
            repository: "google/foresight", revision: String(hash.prefix(40)),
            filename: "\(hash).litertlm", byteCount: size, sha256: hash,
            sourceURL: URL(string: "https://huggingface.co/google")!,
            licenseURL: URL(string: "https://ai.google.dev/gemma/terms")!)
    }

    public enum Source: Sendable { case foresight, huggingFace }

    public struct Candidate: Sendable {
        public let descriptor: LocalModelDescriptor
        public let url: URL
        public let source: Source
    }

    public static var foresightRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai-edge/models")
    }

    /// Bounded, read-only discovery. Never follow manifest paths outside the store.
    public static func discover(in root: URL) -> [Candidate] {
        struct Manifest: Decodable {
            struct Entry: Decodable {
                struct Storage: Decodable {
                    let expectedSizeBytes: Int64
                    let canonicalAbsolutePath: String
                }
                let physicalState: String
                let storage: Storage
            }
            let schemaVersion: Int
            let models: [String: Entry]
        }
        let manifestURL = root.appendingPathComponent(".manifest.json")
        guard let size = try? ModelStorage.fileSize(manifestURL), size > 0, size <= 1024 * 1024,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1 else { return [] }
        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var seen = Set<String>()
        return manifest.models.values.compactMap { entry in
            let url = URL(fileURLWithPath: entry.storage.canonicalAbsolutePath).standardizedFileURL
            guard entry.physicalState == "ready", url.pathExtension == "litertlm",
                  url.resolvingSymlinksInPath().path.hasPrefix(prefix),
                  (try? ModelStorage.fileSize(url)) == entry.storage.expectedSizeBytes,
                  let descriptor = supported.first(where: {
                      $0.engine == .liteRT && $0.byteCount == entry.storage.expectedSizeBytes
                  }), seen.insert(url.path).inserted else { return nil }
            return Candidate(descriptor: descriptor, url: url, source: .foresight)
        }.sorted { $0.url.path < $1.url.path }
    }

    public static func huggingFaceRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        func absolute(_ key: String) -> URL? {
            guard let path = environment[key], path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        }
        if let root = absolute("HF_HUB_CACHE") { return root }
        if let root = absolute("HF_HOME") { return root.appendingPathComponent("hub") }
        let cache = absolute("XDG_CACHE_HOME") ?? home.appendingPathComponent(".cache")
        return cache.appendingPathComponent("huggingface/hub")
    }

    public static func discover() -> [Candidate] {
        var seen = Set<String>()
        return (discover(in: foresightRoot) + discoverHuggingFace(in: huggingFaceRoot()))
            .filter { seen.insert($0.url.resolvingSymlinksInPath().path).inserted }
    }

    /// Scan snapshot files only; never hash weights, access the network or modify the cache.
    /// Resolve HF's snapshot symlinks before passing files to the no-follow verifier.
    public static func discoverHuggingFace(in root: URL) -> [Candidate] {
        let fm = FileManager.default
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path + "/"
        var remaining = 20_000
        var seen = Set<String>()
        var result: [Candidate] = []
        func children(_ directory: URL) -> [URL] {
            guard remaining > 0,
                  let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) else { return [] }
            let bounded = Array(entries.sorted { $0.path < $1.path }.prefix(remaining))
            remaining -= bounded.count
            return bounded
        }
        func isDirectory(_ url: URL) -> Bool {
            (try? fm.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory
        }
        func scan(_ directory: URL, depth: Int) {
            guard depth <= 4 else { return }
            for file in children(directory) {
                if isDirectory(file) { scan(file, depth: depth + 1); continue }
                guard ["gguf", "litertlm"].contains(file.pathExtension) else { continue }
                let resolved = file.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(prefix),
                      let size = try? ModelStorage.fileSize(resolved),
                      let descriptor = supported.first(where: {
                          $0.byteCount == size && ($0.engine == .llama ? "gguf" : "litertlm") == file.pathExtension
                      }), seen.insert(resolved.path).inserted else { continue }
                result.append(Candidate(descriptor: descriptor, url: resolved, source: .huggingFace))
            }
        }
        for repo in children(root) where repo.lastPathComponent.hasPrefix("models--") && isDirectory(repo) {
            let snapshots = repo.appendingPathComponent("snapshots")
            guard isDirectory(snapshots) else { continue }
            for snapshot in children(snapshots) where isDirectory(snapshot) { scan(snapshot, depth: 0) }
        }
        return result
    }

    static func identify(_ url: URL, role: ModelRole, token: ModelVerification,
                         descriptors: [LocalModelDescriptor] = supported) throws -> LocalModelDescriptor {
        let size = try ModelStorage.fileSize(url)
        var checked = Set<String>()
        for descriptor in descriptors where descriptor.role == role && descriptor.byteCount == size
            && checked.insert(descriptor.sha256).inserted {
            do {
                try ModelStorage.verify(url, descriptor: descriptor, token: token)
                return descriptor
            } catch ModelStorageError.checksum { continue }
        }
        throw ExternalModelError.unsupported
    }

    static func descriptor(for receipt: ModelReceipt, role: ModelRole) -> LocalModelDescriptor? {
        supported.first { $0.role == role && $0.sha256 == receipt.sha256 && $0.revision == receipt.revision }
    }
}

enum ExternalModelError: LocalizedError {
    case unsupported
    var errorDescription: String? {
        L10n.text("Этот файл не поддерживается. Выберите проверенную модель Buffera или Foresight для этой функции.")
    }
}
