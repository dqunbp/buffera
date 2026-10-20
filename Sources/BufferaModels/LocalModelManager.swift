import BufferaLocalization
import Foundation

/// State, filesystem mutations and URLSession delegate work share one serial queue.
/// Hashing uses a utility queue and generation tokens so deletion cannot revive a model.
public final class LocalModelManager: @unchecked Sendable {
    private final class Entry {
        let descriptor: LocalModelDescriptor
        var state: ModelState = .notDownloaded
        var received: Int64 = 0
        // The feature preference is independent of download/verification readiness.
        var enabled = false
        var error: String?
        var generation = UUID()
        var download: ModelFileDownload?
        var verification: ModelVerification?
        var needsVerification = false
        var verificationRequests: [(Result<URL, Error>) -> Void] = []
        var lastNotification = Date.distantPast

        init(_ descriptor: LocalModelDescriptor) { self.descriptor = descriptor }
        var snapshot: LocalModelSnapshot {
            LocalModelSnapshot(descriptor: descriptor, state: state, receivedBytes: received,
                               totalBytes: descriptor.byteCount, isEnabled: enabled, errorMessage: error)
        }
    }

    public let rootURL: URL
    private let queue = DispatchQueue(label: "app.buffera.models", qos: .utility)
    private let orderedRoles: [ModelRole]
    private var entries: [ModelRole: Entry]
    private var observer: (([LocalModelSnapshot]) -> Void)?
    private var stopped = false

    public init(rootURL: URL, descriptors: [LocalModelDescriptor] = LocalModelCatalog.models) throws {
        guard Set(descriptors.map(\.role)).count == descriptors.count else {
            throw ModelStorageError.invalidDescriptor
        }
        for descriptor in descriptors { try ModelStorage.validate(descriptor) }
        self.rootURL = rootURL
        self.orderedRoles = descriptors.map(\.role)
        self.entries = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.role, Entry($0)) })
        try ModelStorage.createDirectory(rootURL)
        let receiptURL = rootURL.appendingPathComponent("state.json")
        let receipts: [String: ModelReceipt]
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            _ = try ModelStorage.fileSize(receiptURL)
            receipts = try JSONDecoder().decode([String: ModelReceipt].self, from: Data(contentsOf: receiptURL))
        } else {
            receipts = [:]
        }
        for entry in entries.values {
            let descriptor = entry.descriptor
            let receipt = receipts[descriptor.role.rawValue]
            if receipt?.revision == descriptor.revision && receipt?.sha256 == descriptor.sha256 {
                entry.enabled = receipt?.enabled ?? false
                entry.error = receipt?.error
            }
            for directory in [rootURL.appendingPathComponent(descriptor.role.rawValue), directoryURL(entry)]
            where FileManager.default.fileExists(atPath: directory.path) {
                try ModelStorage.createDirectory(directory)
            }
            let finalSize = try ModelStorage.fileSize(fileURL(entry))
            let partialSize = try ModelStorage.fileSize(partialURL(entry))
            if finalSize > 0 {
                entry.needsVerification = true
                entry.received = min(finalSize, descriptor.byteCount)
                if entry.enabled {
                    entry.state = .verifying
                } else if finalSize == descriptor.byteCount {
                    // Installed but switched-off features do not read gigabytes at app launch.
                    // They cannot expose a usable URL until explicit activation verifies the file.
                    entry.state = .downloaded
                } else {
                    entry.state = .failed
                    entry.error = ModelStorageError.unexpectedSize.localizedDescription
                }
            } else if partialSize > 0 {
                entry.state = .paused
                entry.received = min(partialSize, descriptor.byteCount)
            } else {
                if receipt?.revision == descriptor.revision && receipt?.sha256 == descriptor.sha256 {
                    if let state = receipt?.state, [.downloading, .paused, .verifying].contains(state) {
                        entry.state = .paused
                    } else if receipt?.state == .failed {
                        entry.state = .failed
                    }
                }
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            for entry in self.entries.values where entry.state == .verifying {
                self.verify(entry, at: self.fileURL(entry))
            }
            self.publish()
        }
    }

    public var snapshots: [LocalModelSnapshot] {
        queue.sync { orderedRoles.compactMap { entries[$0]?.snapshot } }
    }

    /// The callback is always delivered on the main queue, including its initial snapshot.
    public var onChange: (([LocalModelSnapshot]) -> Void)? {
        get { queue.sync { observer } }
        set { queue.async { [weak self] in self?.observer = newValue; self?.publish() } }
    }

    /// Returns only a file verified in this process. An installed, switched-off feature
    /// can display as downloaded while verification is deferred until its first activation.
    public func modelURL(for role: ModelRole) -> URL? {
        queue.sync {
            guard let entry = entries[role], entry.state == .downloaded, !entry.needsVerification else { return nil }
            return fileURL(entry)
        }
    }

    /// Verifies an installed file for an explicit diagnostic without enabling its feature
    /// or starting a download. Completion is delivered on the main queue.
    public func verifyInstalledModel(for role: ModelRole,
                                     completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped, let entry = self.entries[role] else {
                DispatchQueue.main.async { completion(.failure(CancellationError())) }
                return
            }
            if entry.state == .verifying {
                entry.verificationRequests.append(completion)
                return
            }
            do {
                guard try ModelStorage.fileSize(self.fileURL(entry)) > 0 else {
                    throw ModelStorageError.notDownloaded
                }
                entry.verificationRequests.append(completion)
                entry.generation = UUID()
                self.verify(entry, at: self.fileURL(entry))
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Downloads or resumes the required files without changing the feature preference.
    public func download(_ role: ModelRole) {
        queue.async { [weak self] in
            guard let self, !self.stopped, let entry = self.entries[role] else { return }
            self.startDownload(entry)
        }
    }

    private func startDownload(_ entry: Entry) {
        guard entry.state != .downloading, entry.state != .verifying,
              entry.state != .downloaded || entry.needsVerification else { return }
        do {
            try prepareDirectory(entry)
            if try ModelStorage.fileSize(fileURL(entry)) > 0 {
                entry.generation = UUID()
                verify(entry, at: fileURL(entry))
                return
            }
            let partial = partialURL(entry)
            let size = try ModelStorage.fileSize(partial)
            if size > entry.descriptor.byteCount {
                try FileManager.default.removeItem(at: partial)
                entry.received = 0
            } else {
                entry.received = size
            }
            entry.error = nil
            entry.generation = UUID()
            if entry.received == entry.descriptor.byteCount {
                verify(entry, at: partial)
                return
            }
            if let free = try rootURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage,
               free < entry.descriptor.byteCount - entry.received + 16 * 1024 * 1024 {
                throw ModelStorageError.insufficientSpace
            }
            entry.state = .downloading
            try persist()
            let generation = entry.generation
            let download = ModelFileDownload(
                descriptor: entry.descriptor, partialURL: partial, offset: entry.received,
                queue: queue,
                onProgress: { [weak self, weak entry] bytes in
                    guard let self, let entry, entry.generation == generation else { return }
                    entry.received = bytes
                    if Date().timeIntervalSince(entry.lastNotification) >= 0.1 {
                        entry.lastNotification = Date()
                        self.publish()
                    }
                },
                onComplete: { [weak self, weak entry] error in
                    guard let self, let entry, entry.generation == generation else { return }
                    entry.download = nil
                    if let error { self.fail(entry, error) }
                    else { self.verify(entry, at: partial) }
                }
            )
            entry.download = download
            download.start()
            publish()
        } catch { fail(entry, error) }
    }

    public func pause(_ role: ModelRole) {
        queue.async { [weak self] in
            guard let self, !self.stopped, let entry = self.entries[role],
                  entry.state == .downloading || entry.state == .verifying else { return }
            self.cancel(entry)
            entry.state = .paused
            entry.error = nil
            self.saveAndPublish(entry)
        }
    }

    public func remove(_ role: ModelRole) {
        queue.async { [weak self] in
            guard let self, !self.stopped, let entry = self.entries[role] else { return }
            self.cancel(entry)
            entry.enabled = false
            do {
                let directory = self.rootURL.appendingPathComponent(role.rawValue, isDirectory: true)
                if FileManager.default.fileExists(atPath: directory.path) {
                    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        throw ModelStorageError.unsafeFile
                    }
                    try FileManager.default.removeItem(at: directory)
                }
                entry.state = .notDownloaded
                entry.needsVerification = false
                entry.received = 0
                entry.error = nil
                self.saveAndPublish(entry)
            } catch { self.fail(entry, error) }
        }
    }

    /// Enabling a feature prepares its files as needed; readiness remains state-gated.
    public func setEnabled(_ enabled: Bool, for role: ModelRole) {
        queue.async { [weak self] in
            guard let self, !self.stopped, let entry = self.entries[role] else { return }
            entry.enabled = enabled
            entry.error = nil
            if enabled && entry.state == .downloaded && entry.needsVerification {
                entry.generation = UUID()
                self.verify(entry, at: self.fileURL(entry))
                return
            }
            if enabled && ![.downloaded, .downloading, .verifying].contains(entry.state) {
                self.startDownload(entry)
                return
            }
            if !enabled && [.downloading, .verifying].contains(entry.state) {
                self.cancel(entry)
                entry.state = .paused
            }
            self.saveAndPublish(entry)
        }
    }

    public func shutdown() {
        queue.sync {
            stopped = true
            for entry in entries.values where entry.state == .downloading || entry.state == .verifying {
                cancel(entry)
                entry.state = .paused
            }
            do { try persist() }
            catch {
                for entry in entries.values { entry.error = error.localizedDescription }
            }
            publish()
        }
    }

    private func verify(_ entry: Entry, at url: URL) {
        entry.state = .verifying
        entry.needsVerification = true
        entry.error = nil
        let generation = entry.generation
        let token = ModelVerification()
        entry.verification = token
        let descriptor = entry.descriptor
        saveAndPublish(entry)
        guard entry.state == .verifying else { return }
        DispatchQueue.global(qos: .utility).async { [weak self, weak entry] in
            let result = Result { _ = try ModelStorage.verify(url, descriptor: descriptor, token: token) }
            self?.queue.async { [weak self, weak entry] in
                guard let self, let entry, entry.generation == generation else { return }
                entry.verification = nil
                do {
                    try result.get()
                    let destination = self.fileURL(entry)
                    if url != destination {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.moveItem(at: url, to: destination)
                    }
                    entry.state = .downloaded
                    entry.needsVerification = false
                    entry.received = descriptor.byteCount
                    self.saveAndPublish(entry)
                    if entry.state == .downloaded {
                        self.finishVerificationRequests(entry, result: .success(destination))
                    }
                } catch {
                    if error is ModelStorageError {
                        do {
                            if FileManager.default.fileExists(atPath: url.path) {
                                try FileManager.default.removeItem(at: url)
                            }
                            entry.received = 0
                        } catch { self.fail(entry, error); return }
                    }
                    self.fail(entry, error)
                }
            }
        }
    }

    private func finishVerificationRequests(_ entry: Entry, result: Result<URL, Error>) {
        let requests = entry.verificationRequests
        entry.verificationRequests.removeAll()
        guard !requests.isEmpty else { return }
        DispatchQueue.main.async { requests.forEach { $0(result) } }
    }

    private func cancel(_ entry: Entry, error: Error = CancellationError()) {
        entry.generation = UUID()
        entry.download?.cancel()
        entry.download = nil
        entry.verification?.cancel()
        entry.verification = nil
        finishVerificationRequests(entry, result: .failure(error))
    }

    private func prepareDirectory(_ entry: Entry) throws {
        try ModelStorage.createDirectory(rootURL)
        try ModelStorage.createDirectory(rootURL.appendingPathComponent(entry.descriptor.role.rawValue))
        try ModelStorage.createDirectory(directoryURL(entry))
    }

    private func directoryURL(_ entry: Entry) -> URL {
        rootURL.appendingPathComponent(entry.descriptor.role.rawValue)
            .appendingPathComponent(entry.descriptor.revision, isDirectory: true)
    }

    private func fileURL(_ entry: Entry) -> URL {
        directoryURL(entry).appendingPathComponent(entry.descriptor.filename)
    }

    private func partialURL(_ entry: Entry) -> URL {
        fileURL(entry).appendingPathExtension("part")
    }

    private func persist() throws {
        let receipts = Dictionary(uniqueKeysWithValues: entries.values.map {
            ($0.descriptor.role.rawValue, ModelReceipt(revision: $0.descriptor.revision,
                                                      sha256: $0.descriptor.sha256,
                                                      state: $0.state, enabled: $0.enabled, error: $0.error))
        })
        let data = try JSONEncoder().encode(receipts)
        try data.write(to: rootURL.appendingPathComponent("state.json"), options: .atomic)
    }

    private func saveAndPublish(_ entry: Entry) {
        do { try persist() }
        catch {
            cancel(entry, error: error)
            entry.state = .failed
            entry.error = L10n.text("Не удалось сохранить состояние функции: \(error.localizedDescription)")
        }
        publish()
    }

    private func fail(_ entry: Entry, _ error: Error) {
        cancel(entry, error: error)
        entry.state = .failed
        entry.error = error.localizedDescription
        saveAndPublish(entry)
    }

    private func publish() {
        guard let observer else { return }
        let value = orderedRoles.compactMap { entries[$0]?.snapshot }
        DispatchQueue.main.async { observer(value) }
    }
}
