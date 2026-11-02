import Foundation
import BufferaLocalization
import BufferaModels

enum SetupStep: Int, CaseIterable {
    case language, shortcuts, storage, mcp, models

    var title: String {
        switch self {
        case .language: return L10n.text("Язык и тема")
        case .shortcuts: return L10n.text("Клавиши")
        case .storage: return L10n.text("Хранение")
        case .mcp: return "MCP"
        case .models: return L10n.text("Поиск и ответы")
        }
    }
}

/// A draft only. Creating, editing and skipping pages never writes preferences.
struct SetupPreferences {
    static let completionKey = "setup.completedVersion"
    var language: LanguagePreference
    var theme: InterfaceTheme
    var limits: HistoryLimits
    var mcpEnabled: Bool
    var embeddingEnabled: Bool
    var assistantEnabled: Bool
    var onlyOnExternalPower: Bool

    init(defaults: UserDefaults = .standard, mcpEnabled: Bool, snapshots: [LocalModelSnapshot]) {
        language = .load(from: defaults)
        theme = .load(from: defaults)
        limits = .load(from: defaults)
        self.mcpEnabled = mcpEnabled
        embeddingEnabled = snapshots.contains { $0.descriptor.role == .embedding && $0.isEnabled }
        assistantEnabled = snapshots.contains { $0.descriptor.role == .assistant && $0.isEnabled }
        onlyOnExternalPower = defaults.object(forKey: BackgroundPreparationPolicy.preferenceKey) as? Bool ?? true
    }

    mutating func skip(_ step: SetupStep, restoring initial: Self) {
        switch step {
        case .language: language = initial.language; theme = initial.theme
        case .shortcuts: break
        case .storage: limits = initial.limits
        case .mcp: mcpEnabled = initial.mcpEnabled
        case .models:
            embeddingEnabled = initial.embeddingEnabled; assistantEnabled = initial.assistantEnabled
            onlyOnExternalPower = initial.onlyOnExternalPower
        }
    }
}
