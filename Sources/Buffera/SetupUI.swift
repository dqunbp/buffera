import AppKit

/// Small native layout helpers shared by the two introductory windows.
enum SetupUI {
    static func text(_ value: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func column(_ views: [NSView], spacing: CGFloat = 16) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    static func card(_ views: [NSView], tinted: Bool = false) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor; box.borderWidth = 0.5; box.cornerRadius = 10
        box.fillColor = tinted ? BrandIdentity.accentColor.withAlphaComponent(0.08) : .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 16, height: 14)
        let stack = column(views, spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor)
        ])
        return box
    }

    static func instruction(_ number: Int, title: String, keys: [String], details: [NSView]) -> NSView {
        let row = NSView()
        let rail = NSBox()
        rail.boxType = .custom
        rail.borderWidth = 0
        rail.fillColor = BrandIdentity.accentColor.withAlphaComponent(0.38)
        let badge = NSBox()
        badge.boxType = .custom
        badge.cornerRadius = 14
        badge.borderWidth = 1
        badge.borderColor = BrandIdentity.accentColor.withAlphaComponent(0.7)
        badge.fillColor = BrandIdentity.accentColor.withAlphaComponent(0.18)
        let digit = text(String(number), size: 14, bold: true)
        digit.textColor = BrandIdentity.accentColor
        badge.contentView!.addSubview(digit)
        digit.translatesAutoresizingMaskIntoConstraints = false
        let caps = keys.map { key -> NSView in
            let cap = NSBox()
            cap.boxType = .custom
            cap.cornerRadius = 6
            cap.fillColor = .controlBackgroundColor
            cap.borderColor = .separatorColor
            cap.borderWidth = 1
            let label = text(key, size: 15, bold: true)
            cap.contentView!.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: cap.centerXAnchor), label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
                cap.widthAnchor.constraint(equalTo: label.widthAnchor, constant: 18), cap.heightAnchor.constraint(equalToConstant: 29)
            ])
            return cap
        }
        let header = NSStackView(views: [text(title, size: 17, bold: true), NSView()] + caps)
        header.spacing = 5
        let content = column([header] + details, spacing: 8)
        for view in [rail, badge, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4), badge.topAnchor.constraint(equalTo: row.topAnchor),
            badge.widthAnchor.constraint(equalToConstant: 28), badge.heightAnchor.constraint(equalToConstant: 28),
            digit.centerXAnchor.constraint(equalTo: badge.centerXAnchor), digit.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            rail.centerXAnchor.constraint(equalTo: badge.centerXAnchor), rail.widthAnchor.constraint(equalToConstant: 1),
            rail.topAnchor.constraint(equalTo: badge.bottomAnchor),
            rail.bottomAnchor.constraint(equalTo: number == 3 ? badge.bottomAnchor : row.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: row.topAnchor),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -24)
        ])
        return row
    }

    static func scroll(_ content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedView()
        scroll.documentView = document
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        return scroll
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
}
