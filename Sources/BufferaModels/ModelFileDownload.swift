import Foundation

/// One streaming transfer. All mutable state and callbacks use the manager's serial queue.
final class ModelFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let descriptor: LocalModelDescriptor
    private let partialURL: URL
    private let queue: DispatchQueue
    private let onProgress: (Int64) -> Void
    private let onComplete: (Error?) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var received: Int64
    private var failure: Error?

    init(descriptor: LocalModelDescriptor, partialURL: URL, offset: Int64,
         queue: DispatchQueue, onProgress: @escaping (Int64) -> Void,
         onComplete: @escaping (Error?) -> Void) {
        self.descriptor = descriptor
        self.partialURL = partialURL
        self.received = offset
        self.queue = queue
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        delegates.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
        self.session = session
        var request = URLRequest(url: descriptor.sourceURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    /// Closing first makes pause/delete safe against already enqueued delegate callbacks.
    func cancel() {
        failure = URLError(.cancelled)
        task?.cancel()
        try? handle?.close()
        handle = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard failure == nil else { throw URLError(.cancelled) }
            guard let response = response as? HTTPURLResponse else { throw ModelStorageError.invalidResponse }
            switch response.statusCode {
            case 200:
                // A server may ignore Range. Start from zero rather than append duplicate bytes.
                received = 0
            case 206:
                guard validContentRange(response.value(forHTTPHeaderField: "Content-Range")) else {
                    throw ModelStorageError.invalidRange
                }
            default:
                throw ModelStorageError.http(response.statusCode)
            }
            let remaining = descriptor.byteCount - received
            if response.expectedContentLength >= 0, response.expectedContentLength != remaining {
                throw ModelStorageError.unexpectedSize
            }
            if !FileManager.default.fileExists(atPath: partialURL.path) {
                guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            guard (try partialURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw ModelStorageError.unsafeFile
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            self.handle = handle
            try handle.truncate(atOffset: UInt64(received))
            try handle.seek(toOffset: UInt64(received))
            onProgress(received)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            guard Int64(data.count) <= descriptor.byteCount - received else {
                throw ModelStorageError.unexpectedSize
            }
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            onProgress(received)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.synchronize(); try handle?.close() }
        catch { if failure == nil { failure = error } }
        handle = nil
        let finalError = failure ?? error ?? (received == descriptor.byteCount ? nil : ModelStorageError.unexpectedSize)
        self.task = nil
        self.session = nil
        session.finishTasksAndInvalidate()
        onComplete(finalError)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Hub uses HTTPS CDN redirects. Never follow a downgrade or a non-network scheme.
        let allowed = request.url?.scheme == "https" ||
            (descriptor.sourceURL.scheme == "http" && request.url?.host == descriptor.sourceURL.host)
        if !allowed { failure = ModelStorageError.invalidResponse }
        completionHandler(allowed ? request : nil)
    }

    private func validContentRange(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("bytes ") else { return false }
        let parts = header.dropFirst(6).split(separator: "/")
        guard parts.count == 2, Int64(parts[1]) == descriptor.byteCount else { return false }
        let range = parts[0].split(separator: "-")
        return range.count == 2 && Int64(range[0]) == received &&
            Int64(range[1]) == descriptor.byteCount - 1
    }
}
