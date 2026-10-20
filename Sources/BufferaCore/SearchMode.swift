/// Search preference is independent of the model runtime and shared by all presentation surfaces.
public enum HistorySearchMode: String, Codable, CaseIterable, Sendable {
    case automatic, literal, hybrid
}

public enum ActualSearchMode: String, Codable, Sendable {
    case literal, hybrid
}
