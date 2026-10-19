import BufferaCore
import Foundation

/// SQLite stays on the history queue; only image decoding and Vision run on the utility queue.
final class ImageTextIndexer {
    private let store: HistoryStore
    private let storageQueue: DispatchQueue
    private let recognitionQueue = DispatchQueue(label: "app.buffera.image-text", qos: .utility)
    private let callbackQueue: DispatchQueue
    private let recognize: (ClipPayload) throws -> String
    private let onProgress: (ImageTextProgress) -> Void
    private let onIndexed: () -> Void
    private let onError: (Error) -> Void

    // Accessed exclusively on storageQueue.
    private var started = false
    private var stopped = false
    private var processing = false
    private var reportedError = false

    init(store: HistoryStore, storageQueue: DispatchQueue,
         recognize: @escaping (ClipPayload) throws -> String = ImageTextRecognizer.recognize,
         callbackQueue: DispatchQueue = .main,
         onProgress: @escaping (ImageTextProgress) -> Void,
         onIndexed: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.store = store; self.storageQueue = storageQueue; self.recognize = recognize
        self.callbackQueue = callbackQueue; self.onProgress = onProgress
        self.onIndexed = onIndexed; self.onError = onError
    }

    func start() {
        storageQueue.async {
            guard !self.started, !self.stopped else { return }
            self.started = true
            do { try self.store.retryFailedImageText(); try self.publishProgress(); self.pump() }
            catch { self.report(error) }
        }
    }

    func schedule() {
        storageQueue.async {
            guard self.started, !self.stopped else { return }
            do { try self.publishProgress(); self.pump() }
            catch { self.report(error) }
        }
    }

    func retryFailed() {
        storageQueue.async {
            guard self.started, !self.stopped else { return }
            self.reportedError = false
            do { try self.store.retryFailedImageText(); try self.publishProgress(); self.pump() }
            catch { self.report(error) }
        }
    }

    /// Called outside storageQueue on shutdown. In-flight work remains pending for the next launch.
    func stop() {
        storageQueue.sync { stopped = true }
    }

    private func pump() {
        guard !stopped, !processing else { return }
        do {
            guard let id = try store.nextPendingImageTextID() else { return }
            processing = true
            let payload: ClipPayload
            do { payload = try store.payload(id: id) }
            catch { finish(id: id, result: .failure(error)); return }
            recognitionQueue.async {
                let result = Result { try autoreleasepool { try self.recognize(payload) } }
                self.storageQueue.async { self.finish(id: id, result: result) }
            }
        } catch {
            processing = false
            report(error)
        }
    }

    private func finish(id: Int64, result: Result<String, Error>) {
        guard !stopped else { return }
        processing = false
        do {
            switch result {
            case .success(let text):
                if try store.completeImageText(id: id, text: text), !text.isEmpty {
                    callbackQueue.async { self.onIndexed() }
                }
            case .failure(let error):
                if try store.failImageText(id: id) { report(error) }
            }
            try publishProgress()
            // Yield between jobs so captures, searches and confirmations keep their place in the queue.
            storageQueue.async { self.pump() }
        } catch {
            // A storage failure pauses the drain until a later schedule/retry, avoiding a busy loop.
            report(error)
        }
    }

    private func publishProgress() throws {
        let progress = try store.imageTextProgress()
        callbackQueue.async { self.onProgress(progress) }
    }

    private func report(_ error: Error) {
        guard !reportedError else { return }
        reportedError = true
        callbackQueue.async { self.onError(error) }
    }
}
