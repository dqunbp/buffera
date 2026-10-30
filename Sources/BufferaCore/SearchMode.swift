import Foundation

/// Search preference is independent of the model runtime and shared by all presentation surfaces.
public enum HistorySearchMode: String, Codable, CaseIterable, Sendable {
    case automatic, literal, hybrid

    /// Share the inference threshold with the UI's loading state and typing delay.
    public func usesSemanticSearch(for filter: SearchFilter) -> Bool {
        self != .literal && !filter.concealedOnly &&
            filter.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }
}

public enum ActualSearchMode: String, Codable, Sendable {
    case literal, hybrid
}
