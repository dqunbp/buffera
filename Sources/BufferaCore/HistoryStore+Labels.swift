import Foundation
import CSQLite
import BufferaLocalization

extension HistoryStore {
    /// Labels are public metadata, including on concealed records. Do not index them as content.
    public func setLabel(id: Int64, label: String) throws {
        let normalized = label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard normalized.count <= 120, !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HistoryError.database(L10n.text("Подпись должна содержать не более 120 символов без управляющих знаков."))
        }
        let statement = try prepare("UPDATE clips SET label=? WHERE id=? AND is_favorite=1 RETURNING id")
        defer { sqlite3_finalize(statement) }
        try bind([.text(normalized), .integer(id)], to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE {
            _ = try summary(id: id)
            throw HistoryError.database(L10n.text("Подпись можно изменить только у записи в избранном."))
        }
        guard status == SQLITE_ROW, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    /// Secret deduplication keeps the surviving row's label, or inherits a missing one.
    func inheritLabel(from duplicate: ClipSummary, to id: Int64) throws {
        guard !duplicate.label.isEmpty else { return }
        let statement = try prepare("UPDATE clips SET label=? WHERE id=? AND label=''")
        defer { sqlite3_finalize(statement) }
        try bind([.text(duplicate.label), .integer(id)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
}
