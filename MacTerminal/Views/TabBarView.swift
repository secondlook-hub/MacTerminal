import SwiftUI
import AppKit

extension NSPasteboard.PasteboardType {
    static let terminalTab = NSPasteboard.PasteboardType("com.macterminal.tab-drag")
}

// MARK: - SwiftUI Bridge

struct TabBarView: NSViewRepresentable {
    @ObservedObject var tabManager: TabManager

    func makeCoordinator() -> Coordinator {
        Coordinator(tabManager: tabManager)
    }

    func makeNSView(context: Context) -> TabBarNSView {
        TabBarNSView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: TabBarNSView, context: Context) {
        context.coordinator.tabManager = tabManager
        nsView.reloadTabs()
    }

    class Coordinator {
        var tabManager: TabManager
        init(tabManager: TabManager) { self.tabManager = tabManager }
    }
}

// MARK: - Tab Bar Container

class TabBarNSView: NSView {
    let coordinator: TabBarView.Coordinator
    private let stackView = NSStackView()
    private let plusButton = NSButton()
    private static let bgColor = NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)

    init(coordinator: TabBarView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        setup()
        registerForDraggedTypes([.terminalTab])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Self.bgColor.cgColor

        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        if let img = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab") {
            plusButton.image = img
        }
        plusButton.bezelStyle = .inline
        plusButton.isBordered = false
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.target = self
        plusButton.action = #selector(addTab)
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -4),
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 30),
            plusButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @objc private func addTab() {
        coordinator.tabManager.addLocalShellTab()
    }

    func reloadTabs() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let manager = coordinator.tabManager
        for tab in manager.tabs {
            let item = TabItemNSView(
                tabID: tab.id, title: tab.title,
                isSelected: tab.id == manager.selectedTabID,
                hasUpdate: tab.hasUpdate,
                managerID: manager.id
            )
            item.onSelect = { [weak manager] in manager?.selectTab(tab.id) }
            item.onClose = { [weak manager] in manager?.removeTab(tab.id) }
            stackView.addArrangedSubview(item)
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard decodeDrag(sender) != nil else { return [] }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard decodeDrag(sender) != nil else { return [] }
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let data = decodeDrag(sender) else { return false }
        let dest = coordinator.tabManager
        let pt = convert(sender.draggingLocation, from: nil)
        let idx = insertionIndex(at: pt)

        if data.sourceManagerID == dest.id {
            guard let fromIdx = dest.tabs.firstIndex(where: { $0.id == data.tabID }) else { return false }
            let tab = dest.tabs.remove(at: fromIdx)
            let toIdx = idx > fromIdx ? idx - 1 : idx
            dest.tabs.insert(tab, at: min(toIdx, dest.tabs.count))
            dest.selectTab(tab.id)
        } else {
            WindowManager.shared.transferTab(
                tabID: data.tabID, from: data.sourceManagerID,
                to: dest.id, at: idx
            )
        }
        return true
    }

    private func decodeDrag(_ sender: NSDraggingInfo) -> TabDragData? {
        guard let raw = sender.draggingPasteboard.data(forType: .terminalTab),
              let d = try? JSONDecoder().decode(TabDragData.self, from: raw) else { return nil }
        return d
    }

    private func insertionIndex(at point: NSPoint) -> Int {
        for (i, v) in stackView.arrangedSubviews.enumerated() {
            let f = stackView.convert(v.frame, to: self)
            if point.x < f.midX { return i }
        }
        return stackView.arrangedSubviews.count
    }
}

// MARK: - Tab Item

class TabItemNSView: NSView {
    let tabID: UUID
    let managerID: UUID
    private let isSelected: Bool
    private let hasUpdate: Bool

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private var isHovering = false
    private var mouseDownPoint: NSPoint?
    private var dragStarted = false

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeBtn = NSButton()
    private let accentBar = NSView()

    init(tabID: UUID, title: String, isSelected: Bool, hasUpdate: Bool, managerID: UUID) {
        self.tabID = tabID
        self.isSelected = isSelected
        self.hasUpdate = hasUpdate
        self.managerID = managerID
        super.init(frame: .zero)
        setupViews(title: title)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews(title: String) {
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeBtn.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        closeBtn.bezelStyle = .inline
        closeBtn.isBordered = false
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeBtn)

        accentBar.wantsLayer = true
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -4),
            closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 18),
            closeBtn.heightAnchor.constraint(equalToConstant: 18),
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func updateAppearance() {
        stopBlinkAnimation()

        if isSelected {
            layer?.backgroundColor = NSColor.terminalBG.cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        } else if hasUpdate {
            startBlinkAnimation()
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        let iconAlpha: CGFloat
        let titleAlpha: CGFloat
        if isSelected {
            iconAlpha = 1.0
            titleAlpha = 1.0
        } else if hasUpdate {
            iconAlpha = 0.75
            titleAlpha = 0.85
        } else {
            iconAlpha = 0.35
            titleAlpha = 0.5
        }

        iconView.contentTintColor = .white.withAlphaComponent(iconAlpha)
        titleLabel.textColor = .white.withAlphaComponent(titleAlpha)
        closeBtn.contentTintColor = .white.withAlphaComponent(0.4)
        closeBtn.isHidden = !(isSelected || isHovering)

        if isSelected {
            accentBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        } else if hasUpdate {
            accentBar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        } else {
            accentBar.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func startBlinkAnimation() {
        guard let layer = self.layer else { return }
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = NSColor.clear.cgColor
        anim.toValue = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        anim.duration = 0.9
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "blink")
    }

    private func stopBlinkAnimation() {
        layer?.removeAnimation(forKey: "blink")
    }

    @objc private func closeTapped() { onClose?() }

    // MARK: - Hit Test

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview?.convert(point, to: self),
              bounds.contains(local) else { return nil }
        if closeBtn.frame.contains(local) && !closeBtn.isHidden { return closeBtn }
        return self
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { isHovering = false; updateAppearance() }

    // MARK: - Click & Drag

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !dragStarted else { return }
        let cur = convert(event.locationInWindow, from: nil)
        let dist = hypot(cur.x - start.x, cur.y - start.y)
        if dist > 5 {
            dragStarted = true
            beginTabDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted { onSelect?() }
        mouseDownPoint = nil
        dragStarted = false
    }

    // MARK: - Drag Session

    private func beginTabDrag(with event: NSEvent) {
        let dragData = TabDragData(tabID: tabID, sourceManagerID: managerID)
        guard let json = try? JSONEncoder().encode(dragData) else { return }

        let pbItem = NSPasteboardItem()
        pbItem.setData(json, forType: .terminalTab)
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)

        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            dragItem.setDraggingFrame(bounds, contents: img)
        }

        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
}

// MARK: - NSDraggingSource

extension TabItemNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation == [] else { return }
        // Only detach if dragged outside the source window
        if let win = self.window, !win.frame.contains(screenPoint) {
            DispatchQueue.main.async {
                WindowManager.shared.detachTab(tabID: self.tabID, from: self.managerID, at: screenPoint)
            }
        }
    }
}
