/// Counts derived image-text jobs without loading original clipboard payloads.
public struct ImageTextProgress: Equatable {
    public let pending: Int
    public let complete: Int
    public let failed: Int
    public var total: Int { pending + complete + failed }

    public init(pending: Int = 0, complete: Int = 0, failed: Int = 0) {
        self.pending = pending; self.complete = complete; self.failed = failed
    }
}
