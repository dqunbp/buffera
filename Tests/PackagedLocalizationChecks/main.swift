import Foundation
import BufferaLocalization

guard L10n.text("Настройки", language: "en") == "Settings",
      L10n.text("Настройки", language: "ru") == "Настройки",
      L10n.text("Обновления", language: "en") == "Updates",
      L10n.text("Обновления", language: "ru") == "Обновления" else {
    fatalError("Packaged translations did not load")
}
print("PASS: packaged RU/EN translations with source checkout access denied")
