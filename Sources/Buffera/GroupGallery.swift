import AppKit
import BufferaCore
import BufferaLocalization
import UniformTypeIdentifiers

struct GroupTile {
    let title: String
    let isFile: Bool
    let image: NSImage

    static func previews(_ payload: ClipPayload) -> [Self] {
        guard payload.items.count > 1 else { return [] }
        return payload.items.map { representations in
            let item = ClipPayload(items: [representations])
            let metadata = ClipboardMetadata(payload: item)
            let pixels = ClipboardService.previewImage(item, maximumPixelSize: 128)
            let format = representations.compactMap { UTType($0.type) }.first { $0.conforms(to: .image) }
            let title: String
            if metadata.kind != .file, let format {
                title = [ClipKind.image.label, format.preferredFilenameExtension?.uppercased()].compactMap { $0 }.joined(separator: " · ")
            } else if metadata.kind == .other {
                title = representations.first?.type ?? metadata.kind.label
            } else {
                title = metadata.title
            }
            let image: NSImage
            if let pixels {
                image = pixels
            } else if metadata.kind == .file, let type = UTType(filenameExtension: (metadata.title as NSString).pathExtension) {
                image = NSWorkspace.shared.icon(for: type)
            } else if let type = representations.first.flatMap({ UTType($0.type) }), metadata.kind == .other {
                image = NSWorkspace.shared.icon(for: type)
            } else {
                image = NSImage(systemSymbolName: metadata.kind.symbol, accessibilityDescription: nil) ?? NSImage()
            }
            return Self(title: title, isFile: metadata.kind == .file, image: image)
        }
    }
}

final class GroupFan: NSView {
    let tiles: [GroupTile]
    let title: NSTextField
    let hint = NSTextField(wrappingLabelWithString: L10n.text("Нажмите для просмотра. Потяните, чтобы перенести всю группу."))
    private let mark: CountedFan

    private final class CountedFan: NSView {
        let tiles: [GroupTile]
        var naturalWidth: CGFloat { 39 + CGFloat(String(tiles.count).count * 9) }

        init(_ tiles: [GroupTile]) {
            self.tiles = tiles
            super.init(frame: .zero)
            setAccessibilityLabel(L10n.text("Объектов: \(tiles.count)"))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            guard bounds.height > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let scale = NSAffineTransform()
            scale.scale(by: bounds.height / 26)
            scale.concat()
            for i in (0..<min(3, tiles.count)).reversed() {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: 12 + CGFloat(i * 3), yBy: 4)
                transform.rotate(byDegrees: CGFloat(i * 10))
                transform.concat()
                let cover = NSBezierPath(roundedRect: NSRect(x: -8, y: 0, width: 17, height: 18), xRadius: 2, yRadius: 2)
                NSColor.controlBackgroundColor.setFill(); cover.fill()
                NSColor.secondaryLabelColor.setStroke(); cover.stroke()
                tiles[i].image.draw(in: NSRect(x: -6, y: 2, width: 13, height: 14))
                NSGraphicsContext.restoreGraphicsState()
            }
            String(tiles.count).draw(at: NSPoint(x: 33, y: 5), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ])
        }
    }

    init(_ tiles: [GroupTile], name: String) {
        self.tiles = tiles
        mark = CountedFan(tiles)
        title = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11)
        title.alignment = .center; hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        toolTip = hint.stringValue
        addSubview(title); addSubview(mark); addSubview(hint)
    }

    override func layout() {
        super.layout()
        let content = bounds.insetBy(dx: 4, dy: 2)
        let titleHeight: CGFloat = 17
        let hintHeight = measuredHintHeight(width: content.width)
        let stackedHeight = content.height - titleHeight - hintHeight - 4
        let aspect = mark.naturalWidth / 26

        if stackedHeight < 54 || content.width < 54 * aspect {
            layoutSideBySide(in: content, titleHeight: titleHeight, aspect: aspect)
        } else {
            title.alignment = .center
            hint.alignment = .center
            hint.isHidden = false
            title.frame = NSRect(x: content.minX, y: content.maxY - titleHeight,
                                 width: content.width, height: titleHeight)
            hint.frame = NSRect(x: content.minX, y: title.frame.minY - hintHeight - 1,
                                width: content.width, height: hintHeight)
            let height = min(stackedHeight, content.width / aspect)
            mark.frame = NSRect(x: content.midX - height * aspect / 2,
                                y: content.minY + (stackedHeight - height) / 2,
                                width: height * aspect, height: height)
        }
        mark.needsDisplay = true
    }

    private func layoutSideBySide(in content: NSRect, titleHeight: CGFloat, aspect: CGFloat) {
        let markWidth = max(0, min(content.width * 0.48, content.height * aspect))
        let markHeight = markWidth / aspect
        mark.frame = NSRect(x: content.minX, y: content.midY - markHeight / 2,
                            width: markWidth, height: markHeight)

        let textX = mark.frame.maxX + 6
        let textWidth = max(0, content.maxX - textX)
        title.alignment = .left
        hint.alignment = .left
        let hintHeight = measuredHintHeight(width: textWidth)
        hint.isHidden = titleHeight + hintHeight + 1 > content.height
        let height = hint.isHidden ? titleHeight : titleHeight + hintHeight + 1
        let textTop = content.midY + height / 2
        title.frame = NSRect(x: textX, y: textTop - titleHeight, width: textWidth, height: titleHeight)
        hint.frame = NSRect(x: textX, y: textTop - height, width: textWidth, height: hintHeight)
    }

    private func measuredHintHeight(width: CGFloat) -> CGFloat {
        let area = NSRect(x: 0, y: 0, width: max(1, width), height: 100)
        return ceil(hint.cell?.cellSize(forBounds: area).height ?? 28)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class GroupGallery: NSView {
    let header: NSTextField
    private let hint = NSTextField(labelWithString: L10n.text("Перетащите нужный элемент"))
    private let scroll = NSScrollView()
    private final class Canvas: NSView { override var isFlipped: Bool { true } }
    private let canvas = Canvas()
    final class TileView: NSView {
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        override func layout() {
            super.layout()
            if bounds.height < 48 {
                let side = min(25, bounds.height)
                icon.frame = NSRect(x: 3, y: (bounds.height-side)/2, width: side, height: side)
                label.frame = NSRect(x: side+6, y: (bounds.height-16)/2, width: max(0,bounds.width-side-8), height: 16)
            } else {
                icon.frame = bounds.insetBy(dx: 5, dy: 3).divided(atDistance: 18, from: .minYEdge).remainder
                label.frame = NSRect(x: 4, y: 2, width: bounds.width-8, height: 16)
            }
        }
        var start: ((NSView, NSEvent) -> Void)?
        var cancel: (() -> Void)?
        var down: NSEvent?
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
        override func mouseDown(with event: NSEvent) { down = event }
        override func mouseUp(with event: NSEvent) { down = nil; cancel?() }
        override func mouseDragged(with event: NSEvent) {
            guard let down, hypot(event.locationInWindow.x - down.locationInWindow.x,
                                  event.locationInWindow.y - down.locationInWindow.y) >= 5 else { return }
            self.down = nil
            start?(self, down)
        }
    }

    init(tiles: [GroupTile], name: String, drag: @escaping (Int, NSView, NSEvent) -> Void, cancel: @escaping () -> Void) {
        header = NSTextField(labelWithString: "\(name) · \(tiles.count)")
        super.init(frame: .zero)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = canvas
        addSubview(header); addSubview(hint); addSubview(scroll)
        for (i, tile) in tiles.enumerated() {
            let cell = TileView()
            cell.start = { view, event in drag(i, view, event) }; cell.cancel = cancel
            cell.icon.image = tile.image; cell.icon.imageScaling = .scaleProportionallyUpOrDown
            cell.label.stringValue = tile.title; cell.label.alignment = .center
            cell.label.font = .systemFont(ofSize: 11); cell.label.lineBreakMode = .byTruncatingMiddle
            cell.toolTip = tile.title
            cell.wantsLayer = true; cell.layer?.cornerRadius = 6
            cell.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
            cell.addSubview(cell.icon); cell.addSubview(cell.label); canvas.addSubview(cell)
        }
    }
    override func layout() {
        super.layout()
        let width = max(1, bounds.width - 8)
        header.frame = NSRect(x: 4, y: bounds.height - 19, width: max(1,width-27), height: 18)
        hint.isHidden = bounds.height < 84
        let hintSpace: CGFloat = hint.isHidden ? 0 : 17
        hint.frame = NSRect(x: 4, y: header.frame.minY - 16, width: width, height: 15)
        scroll.frame = NSRect(x: 4, y: 0, width: width, height: max(1,bounds.height-21-hintSpace))
        let count = canvas.subviews.count
        let columns = min(count, max(2, Int(width / 100)))
        let cellWidth = floor((scroll.contentSize.width - CGFloat(columns-1)*5) / CGFloat(columns))
        let rows = (count + columns - 1) / columns
        let rowHeight = max(1, scroll.contentSize.height / CGFloat(min(rows, max(1, Int(scroll.contentSize.height / 80)))))
        let height = CGFloat(rows) * rowHeight
        canvas.frame.size = NSSize(width: scroll.contentSize.width, height: height)
        for (i, cell) in canvas.subviews.enumerated() {
            cell.frame = NSRect(x: CGFloat(i % columns)*(cellWidth+5), y: CGFloat(i / columns)*rowHeight,
                                width: cellWidth, height: max(1, rowHeight-2))
        }

    }
    required init?(coder: NSCoder) { fatalError() }
}
