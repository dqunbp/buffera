import Foundation
import BufferaLocalization
import BufferaModels

enum SetupStep: Int, CaseIterable {
    case language, shortcuts, storage, mcp, models

    var title: String {
        switch self {
        case .language: return L10n.text("Язык и тема")
        case .shortcuts: return L10n.text("Как пользоваться")
        case .storage: return L10n.text("Хранение")
        case .mcp: return "MCP"
        case .models: return L10n.text("Завершение настройки")
        }
    }
}

/// A draft only. Creating, editing and skipping pages never writes preferences.
struct SetupPreferences {
    static let completionKey = "setup.completedVersion"
    var language: LanguagePreference
    var theme: InterfaceTheme
    var pasteOnEnter: Bool
    var limits: HistoryLimits
    var mcpEnabled: Bool
    var embeddingEnabled: Bool
    var assistantEnabled: Bool
    var launchAtLogin: Bool
    var onlyOnExternalPower: Bool

    init(defaults: UserDefaults = .standard, mcpEnabled: Bool, snapshots: [LocalModelSnapshot], launchAtLogin: Bool) {
        self.launchAtLogin = launchAtLogin
        language = .load(from: defaults)
        theme = .load(from: defaults)
        pasteOnEnter = AppPreferences(defaults: defaults).pasteOnEnter
        limits = .load(from: defaults)
        self.mcpEnabled = mcpEnabled
        embeddingEnabled = snapshots.contains { $0.descriptor.role == .embedding && $0.isEnabled }
        assistantEnabled = snapshots.contains { $0.descriptor.role == .assistant && $0.isEnabled }
        onlyOnExternalPower = defaults.object(forKey: BackgroundPreparationPolicy.preferenceKey) as? Bool ?? true
    }

    mutating func skip(_ step: SetupStep, restoring initial: Self) {
        switch step {
        case .language: language = initial.language; theme = initial.theme
        case .shortcuts: pasteOnEnter = initial.pasteOnEnter
        case .storage: limits = initial.limits
        case .mcp: mcpEnabled = initial.mcpEnabled
        case .models:
            launchAtLogin = initial.launchAtLogin
            embeddingEnabled = initial.embeddingEnabled; assistantEnabled = initial.assistantEnabled
            onlyOnExternalPower = initial.onlyOnExternalPower
        }
    }
}
