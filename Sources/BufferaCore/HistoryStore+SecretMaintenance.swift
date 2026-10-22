import Foundation
import CSQLite
import os

extension HistoryStore {
    /// Called inside the transaction that removes plaintext. A rollback also
    /// rolls back this request, and a process exit cannot lose committed work.
    func requestSecretCleanup(includingLegacy: Bool = false) throws {
        try execute("UPDATE secret_maintenance SET needs_checkpoint=1\(includingLegacy ? ",needs_vacuum=1" : "") WHERE singleton=1")
    }

    private func secretMaintenanceState() throws -> (checkpoint: Bool, vacuum: Bool) {
        let statement = try prepare("SELECT needs_checkpoint,needs_vacuum FROM secret_maintenance WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return (sqlite3_column_int(statement, 0) != 0, sqlite3_column_int(statement, 1) != 0)
    }

    /// Best-effort maintenance, on the same serial queue as all store writes.
    /// Returns true while cleanup remains pending. The app retries at a bounded
    /// rate; a busy reader never holds this queue for the normal busy timeout.
    /// Legacy VACUUM may still be expensive, so call at startup or while idle,
    /// never as part of reporting the result of insert/conceal to their caller.
    @discardableResult
    public func performSecretMaintenance() -> Bool {
        sqlite3_busy_timeout(db, 0)
        defer { sqlite3_busy_timeout(db, 3000) }
        do {
            let pending = try secretMaintenanceState()
            guard pending.checkpoint || pending.vacuum else { return false }
            guard try truncateSecretWAL() else { return true }
            if pending.vacuum {
                try execute("VACUUM")
                // Remember that the expensive phase succeeded even if a new
                // reader prevents the final WAL truncation. No plaintext can
                // be introduced by another operation on this serial queue.
                try execute("UPDATE secret_maintenance SET needs_vacuum=0,needs_checkpoint=1 WHERE singleton=1")
                guard try truncateSecretWAL() else { return true }
            }
            try execute("UPDATE secret_maintenance SET needs_checkpoint=0 WHERE singleton=1")
            return false
        } catch {
            Logger(subsystem: "local.buffera.app", category: "secret-maintenance")
                .error("Secret cleanup deferred: \(error.localizedDescription, privacy: .private)")
            return true
        }
    }

    private func truncateSecretWAL() throws -> Bool {
        let status = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if status == SQLITE_BUSY || status == SQLITE_LOCKED { return false }
        guard status == SQLITE_OK else { throw failure() }
        return true
    }
}
