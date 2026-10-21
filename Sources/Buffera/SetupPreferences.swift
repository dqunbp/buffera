import Foundation
import BufferaLocalization
import BufferaModels

/// A draft only. Creating, editing and skipping pages never writes preferences.
struct SetupPreferences {
    static let completionKey = "setup.completedVersion"
    var language: LanguagePreference
    var theme: InterfaceTheme
    var appearance: HistoryAppearance
    var limits: HistoryLimits
    var mcpEnabled: Bool
    var embeddingEnabled: Bool
    var assistantEnabled: Bool
    var onlyOnExternalPower: Bool

    init(defaults: UserDefaults = .standard, mcpEnabled: Bool, snapshots: [LocalModelSnapshot]) {
        language = .load(from: defaults)
        theme = .load(from: defaults)
        appearance = .load(from: defaults)
        limits = .load(from: defaults)
        self.mcpEnabled = mcpEnabled
        embeddingEnabled = snapshots.contains { $0.descriptor.role == .embedding && $0.isEnabled }
        assistantEnabled = snapshots.contains { $0.descriptor.role == .assistant && $0.isEnabled }
        onlyOnExternalPower = defaults.object(forKey: BackgroundPreparationPolicy.preferenceKey) as? Bool ?? true
    }

    mutating func skip(_ step: Int, restoring initial: Self) {
        switch step {
        case 0: language = initial.language; theme = initial.theme
        case 1: appearance = initial.appearance
        case 3: limits = initial.limits
        case 4: mcpEnabled = initial.mcpEnabled
        case 5:
            embeddingEnabled = initial.embeddingEnabled; assistantEnabled = initial.assistantEnabled
            onlyOnExternalPower = initial.onlyOnExternalPower
        default: break
        }
    }
}
