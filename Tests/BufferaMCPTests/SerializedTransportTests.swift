import Foundation
import Logging
import MCP
import BufferaMCPKit

func runSerializedTransportChecks() async throws {
    try await checkYieldingWritesNeverInterleave()
    print("PASS: concurrent yielding transport sends stay serialized and receive is forwarded")
    try await checkDisconnectCancelsWrites()
    print("PASS: disconnect cancels active and queued transport sends")
}

private func checkYieldingWritesNeverInterleave() async throws {
    let underlying = YieldingTransport(delay: 20_000_000)
    let transport = SerializedTransport(underlying)
    try await transport.connect()
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask { try await transport.send(Data("message-\(index)".utf8)) }
            }
            try await group.waitForAll()
        }
        let writes = await underlying.writes
        try checkEqual(writes.count, 12)
        for index in stride(from: 0, to: writes.count, by: 2) {
            try checkEqual(writes[index].replacingOccurrences(of: "begin:", with: ""),
                           writes[index + 1].replacingOccurrences(of: "end:", with: ""))
        }
        let maximumConcurrentSends = await underlying.maximumConcurrentSends
        try checkEqual(maximumConcurrentSends, 1)
        let incoming = await transport.receive()
        await underlying.deliver(Data("incoming".utf8))
        var iterator = incoming.makeAsyncIterator()
        let message = try await iterator.next()
        try checkEqual(message, Data("incoming".utf8))
        await transport.disconnect()
        let end = try await iterator.next()
        try checkNil(end)
    } catch {
        await transport.disconnect()
        throw error
    }
}

private func checkDisconnectCancelsWrites() async throws {
    let underlying = YieldingTransport(delay: 30_000_000_000)
    let transport = SerializedTransport(underlying)
    try await transport.connect()
    let first = Task { try await transport.send(Data("first".utf8)) }
    for _ in 0..<2_000 {
        if await !underlying.writes.isEmpty { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    let initialWrites = await underlying.writes
    guard initialWrites == ["begin:first"] else {
        await transport.disconnect()
        throw TransportCheckError.didNotStart
    }
    let second = Task { try await transport.send(Data("second".utf8)) }
    // Let the second caller enter the queue while the first underlying send remains suspended.
    try await Task.sleep(nanoseconds: 20_000_000)
    await transport.disconnect()
    for task in [first, second] {
        let result = await task.result
        try checkTrue(isCancellation(result))
    }
    let writes = await underlying.writes
    try checkEqual(writes, ["begin:first"])
    let disconnects = await underlying.disconnects
    try checkEqual(disconnects, 1)
    let afterDisconnect = Task { try await transport.send(Data("after disconnect".utf8)) }
    let result = await afterDisconnect.result
    try checkTrue(isCancellation(result))
}

private func isCancellation(_ result: Result<Void, Error>) -> Bool {
    if case .failure(let error) = result { return error is CancellationError }
    return false
}

private enum TransportCheckError: Error { case didNotStart }

/// Deliberately reentrant, like a nonblocking stdio write waiting for room in its pipe.
private actor YieldingTransport: Transport {
    nonisolated let logger = Logger(label: "buffera.tests.yielding-transport",
                                    factory: { _ in SwiftLogNoOpLogHandler() })
    private let delay: UInt64
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var connected = false
    private var activeSends = 0
    private(set) var maximumConcurrentSends = 0
    private(set) var writes: [String] = []
    private(set) var disconnects = 0

    init(delay: UInt64) {
        self.delay = delay
        let pair = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connect() { connected = true }

    func send(_ data: Data) async throws {
        guard connected else { throw CancellationError() }
        activeSends += 1
        maximumConcurrentSends = max(maximumConcurrentSends, activeSends)
        defer { activeSends -= 1 }
        let text = String(decoding: data, as: UTF8.self)
        writes.append("begin:\(text)")
        try await Task.sleep(nanoseconds: delay)
        try Task.checkCancellation()
        writes.append("end:\(text)")
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }
    func deliver(_ data: Data) { continuation.yield(data) }

    func disconnect() {
        connected = false
        disconnects += 1
        continuation.finish()
    }
}
