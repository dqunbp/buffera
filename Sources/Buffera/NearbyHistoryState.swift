import BufferaLocalization
import AppKit
import BufferaCore

/// A temporary chronological view keeps the underlying search controls intact.
struct NearbyHistoryState {
    struct ReturnPoint {
        let rows: [ClipSummary]
        let total: Int
        let selectedID: Int64?
        let viewport: NSPoint
    }

    let returnPoint: ReturnPoint
    var anchorID: Int64
    var anchorDate: Date
    var needsReload = false

    var title: String {
        L10n.text("Рядом с копированием \(anchorDate.formatted(.dateTime.day().month(.abbreviated).hour().minute().second().locale(L10n.locale)))")
    }
}
