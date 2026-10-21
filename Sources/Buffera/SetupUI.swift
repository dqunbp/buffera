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
