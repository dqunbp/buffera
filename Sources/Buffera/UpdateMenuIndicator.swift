import AppKit
import BufferaLocalization
import BufferaUpdates

/// One release state drives the colored overlay and its matching menu action.
@MainActor final class UpdateMenuIndicator: NSObject {
    let menuItem = NSMenuItem(title: L10n.text("Обновления"), action: nil, keyEquivalent: "")
    var onOpenSettings: (() -> Void)?
    private weak var button: NSButton?
    private let dots = UpdateDotsView(image: BrandIdentity.updateDotsImage())

    init(button: NSButton) {
        self.button = button
        super.init()
        dots.identifier = .init("updates.menuBarDots")
        dots.setAccessibilityElement(false)
        dots.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dots)
        NSLayoutConstraint.activate([
            dots.widthAnchor.constraint(equalToConstant: 20),
            dots.heightAnchor.constraint(equalToConstant: 18),
            dots.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        menuItem.image = BrandIdentity.updateDotsImage()
        menuItem.target = self; menuItem.action = #selector(openSettings)
        update(release: nil)
    }

    func update(release: ReleaseUpdate?) {
        dots.isHidden = release == nil
        menuItem.isHidden = release == nil
        menuItem.title = release.map { L10n.text("Доступна Buffera \($0.version.description)…") } ?? L10n.text("Обновления")
        let description = release.map { L10n.text("Доступна Buffera \($0.version.description). Настройки → Обновления.") }
            ?? L10n.text("\(BrandIdentity.name) — история буфера обмена")
        button?.toolTip = description
        button?.setAccessibilityLabel(description)
    }

    @objc private func openSettings() {
        guard !menuItem.isHidden else { return }
        onOpenSettings?()
    }
}

private final class UpdateDotsView: NSImageView {
    // The status button must keep receiving clicks, including directly on a dot.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
