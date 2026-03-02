import SwiftUI
import AppKit

struct TerminalView: NSViewRepresentable {
    @ObservedObject var tab: TerminalTab

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class Coordinator {
        let container: TerminalContainerView
        init(tab: TerminalTab) {
            container = TerminalContainerView(terminal: tab.terminal, screen: tab.screen)
        }
    }
}

// MARK: - Find Bar

class FindBarView: NSView, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var themeObserver: NSObjectProtocol?

    var onSearch: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ThemeManager.shared.findBarBG.cgColor

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.layer?.backgroundColor = ThemeManager.shared.findBarBG.cgColor
        }

        searchField.placeholderString = "Find..."
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        addSubview(searchField)

        prevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        prevButton.bezelStyle = .inline; prevButton.isBordered = false
        prevButton.target = self; prevButton.action = #selector(prevTapped)
        prevButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(prevButton)

        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        nextButton.bezelStyle = .inline; nextButton.isBordered = false
        nextButton.target = self; nextButton.action = #selector(nextTapped)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nextButton)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        closeButton.bezelStyle = .inline; closeButton.isBordered = false
        closeButton.target = self; closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            prevButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 4),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = themeObserver { NotificationCenter.default.removeObserver(o) } }

    func updateCount(current: Int, total: Int) {
        countLabel.stringValue = total > 0 ? "\(current)/\(total)" : "No results"
    }

    @objc private func searchChanged() { onSearch?(searchField.stringValue) }
    @objc private func prevTapped() { onPrev?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func closeTapped() { onClose?() }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            onNext?(); return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            onClose?(); return true
        }
        return false
    }
}

// MARK: - Container (scroll view + draw view)

class TerminalContainerView: NSView {
    let scrollView = NSScrollView()
    let drawView: TerminalDrawView
    let findBar = FindBarView()
    let statusBar = StatusBarView()
    static let statusBarHeight: CGFloat = 20
    let screen: TerminalScreen
    let terminal: PseudoTerminal
    var lastCols = 0
    var lastRows = 0
    private var findBarTop: NSLayoutConstraint!
    private var scrollViewTop: NSLayoutConstraint!
    private(set) var isFindBarVisible = false
    var onFocused: (() -> Void)?

    init(terminal: PseudoTerminal, screen: TerminalScreen) {
        self.terminal = terminal
        self.screen = screen
        self.drawView = TerminalDrawView()
        super.init(frame: .zero)

        drawView.screen = screen
        drawView.terminal = terminal
        drawView.onFocused = { [weak self] in self?.onFocused?() }
        drawView.onSelectionChange = { [weak self] sel in
            self?.updateStatusBar(selection: sel)
        }
        setupUI()
        setupFindBar()
        setupStatusBar()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        scrollViewTop = scrollView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            scrollViewTop,
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.statusBarHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = drawView.bgColor
        scrollView.documentView = drawView
    }

    private func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(findBar)
        findBarTop = findBar.topAnchor.constraint(equalTo: topAnchor, constant: -32)
        NSLayoutConstraint.activate([
            findBarTop,
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        findBar.isHidden = true

        findBar.onSearch = { [weak self] query in self?.performSearch(query) }
        findBar.onNext = { [weak self] in self?.navigateMatch(forward: true) }
        findBar.onPrev = { [weak self] in self?.navigateMatch(forward: false) }
        findBar.onClose = { [weak self] in self?.toggleFindBar(show: false) }
    }

    private func setupStatusBar() {
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
        ])
    }

    func updateStatusBar(selection: (start: (row: Int, col: Int), end: (row: Int, col: Int))? = nil) {
        var logicalLine = 0
        for i in 0..<screen.scrollback.count {
            if i >= screen.scrollbackWrapped.count || !screen.scrollbackWrapped[i] {
                logicalLine += 1
            }
        }
        for r in 0...screen.cursorRow {
            if r >= screen.gridWrapped.count || !screen.gridWrapped[r] {
                logicalLine += 1
            }
        }
        let col = screen.cursorCol + 1
        var text = "Ln \(logicalLine), Col \(col)"
        if let sel = selection {
            let s = sel.start
            let e = sel.end
            text += "  |  Sel \(s.row + 1):\(s.col + 1) - \(e.row + 1):\(e.col + 1)"
        }
        statusBar.update(text)
    }

    func toggleFindBar(show: Bool) {
        isFindBarVisible = show
        if show {
            findBar.isHidden = false
            findBarTop.constant = 0
            scrollViewTop.constant = 32
            window?.makeFirstResponder(findBar.searchField)
        } else {
            findBarTop.constant = -32
            scrollViewTop.constant = 0
            findBar.isHidden = true
            drawView.searchMatches = []
            drawView.currentMatchIndex = -1
            drawView.needsDisplay = true
            window?.makeFirstResponder(drawView)
        }
        needsLayout = true
    }

    private func performSearch(_ query: String) {
        guard !query.isEmpty else {
            drawView.searchMatches = []
            drawView.currentMatchIndex = -1
            findBar.updateCount(current: 0, total: 0)
            drawView.needsDisplay = true
            return
        }

        var matches: [(line: Int, col: Int, length: Int)] = []
        let lowerQuery = query.lowercased()
        let totalLines = screen.scrollback.count + screen.rows

        for lineIdx in 0..<totalLines {
            let cells: [TerminalScreen.Cell]
            if lineIdx < screen.scrollback.count {
                cells = screen.scrollback[lineIdx]
            } else {
                let sr = lineIdx - screen.scrollback.count
                guard sr < screen.rows else { continue }
                cells = screen.grid[sr]
            }
            // Build line string with column mapping
            var lineStr = ""
            var colMap: [Int] = [] // lineStr index -> cell column
            for c in 0..<min(cells.count, screen.cols) {
                if cells[c].widePadding { continue }
                colMap.append(c)
                lineStr.append(cells[c].char)
            }
            // Search
            let lowerLine = lineStr.lowercased()
            var searchStart = lowerLine.startIndex
            while let range = lowerLine.range(of: lowerQuery, range: searchStart..<lowerLine.endIndex) {
                let startIdx = lowerLine.distance(from: lowerLine.startIndex, to: range.lowerBound)
                let len = lowerQuery.count
                if startIdx < colMap.count {
                    matches.append((line: lineIdx, col: colMap[startIdx], length: len))
                }
                searchStart = range.upperBound
            }
        }

        drawView.searchMatches = matches
        drawView.currentMatchIndex = matches.isEmpty ? -1 : 0
        findBar.updateCount(current: matches.isEmpty ? 0 : 1, total: matches.count)
        if !matches.isEmpty { scrollToMatch(0) }
        drawView.needsDisplay = true
    }

    private func navigateMatch(forward: Bool) {
        let matches = drawView.searchMatches
        guard !matches.isEmpty else { return }
        var idx = drawView.currentMatchIndex
        idx = forward ? idx + 1 : idx - 1
        if idx >= matches.count { idx = 0 }
        if idx < 0 { idx = matches.count - 1 }
        drawView.currentMatchIndex = idx
        findBar.updateCount(current: idx + 1, total: matches.count)
        scrollToMatch(idx)
        drawView.needsDisplay = true
    }

    private func scrollToMatch(_ index: Int) {
        let match = drawView.searchMatches[index]
        let y = CGFloat(match.line) * drawView.cellHeight
        let visibleHeight = scrollView.contentView.bounds.height
        let scrollY = max(0, y - visibleHeight / 2)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Connect this container's display refresh to a TerminalPane's data pipeline.
    func bindToPane(_ pane: TerminalPane) {
        pane.onScreenUpdate = { [weak self] in
            self?.refreshDisplay()
        }
    }

    func refreshDisplay() {
        let totalLines = screen.scrollback.count + screen.rows
        let contentHeight = CGFloat(totalLines) * drawView.cellHeight + drawView.paddingBottom
        let height = max(contentHeight, scrollView.contentSize.height)
        let width = scrollView.contentSize.width

        drawView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        drawView.needsDisplay = true

        // Auto-scroll to bottom
        let clipView = scrollView.contentView
        let maxY = max(0, height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(clipView)

        updateStatusBar()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let availableHeight = bounds.height - Self.statusBarHeight
        let availableWidth = bounds.width - drawView.paddingLeft - drawView.timestampWidth
        let cols = max(Int(availableWidth / drawView.cellWidth), 20)
        let rows = max(Int((availableHeight - drawView.paddingBottom) / drawView.cellHeight), 5)

        if cols != lastCols || rows != lastRows {
            lastCols = cols; lastRows = rows
            screen.resize(newRows: rows, newCols: cols)
            terminal.resize(cols: UInt16(cols), rows: UInt16(rows))
            refreshDisplay()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(drawView)
        onFocused?()
        return true
    }
}

// MARK: - Custom Drawing View

class TerminalDrawView: NSView, NSUserInterfaceValidations {
    var screen: TerminalScreen!
    weak var terminal: PseudoTerminal?
    var onFocused: (() -> Void)?
    var onSelectionChange: (((start: (row: Int, col: Int), end: (row: Int, col: Int))?) -> Void)?

    var cellWidth: CGFloat
    var cellHeight: CGFloat
    static let basePaddingLeft: CGFloat = 4
    var paddingLeft: CGFloat = 4
    var paddingBottom: CGFloat  // one line height, set after cellHeight
    var defaultFont: NSFont
    var boldFont: NSFont
    var showTimestamp = UserDefaults.standard.bool(forKey: "showTimestamp")
    private(set) var timestampWidth: CGFloat = 0
    private lazy var timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    var showLineNumber = UserDefaults.standard.bool(forKey: "showLineNumber")
    private(set) var lineNumberWidth: CGFloat = 0

    // Appearance
    var bgColor: NSColor
    var fgColor: NSColor
    private enum ColorEditTarget { case background, foreground }
    private var colorEditTarget: ColorEditTarget = .background

    // Selection
    private enum SelectionMode { case line, block }
    private var selectionMode: SelectionMode = .line
    private var selStart: (row: Int, col: Int)?
    private var selEnd: (row: Int, col: Int)?

    // Search
    var searchMatches: [(line: Int, col: Int, length: Int)] = []
    var currentMatchIndex: Int = -1

    // Cursor blink
    private var cursorOn = true
    private var blinkTimer: Timer?
    private var themeObserver: NSObjectProtocol?

    // IME composition
    private var markedString: String?
    private var _inputContext: NSTextInputContext?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var inputContext: NSTextInputContext? {
        if _inputContext == nil {
            _inputContext = NSTextInputContext(client: self)
        }
        return _inputContext
    }

    override init(frame: NSRect) {
        let fontSize: CGFloat = {
            let s = UserDefaults.standard.double(forKey: "terminalFontSize")
            return s > 0 ? s : 13
        }()
        if let name = UserDefaults.standard.string(forKey: "terminalFontName"),
           let f = NSFont(name: name, size: fontSize) {
            defaultFont = f
            boldFont = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        } else {
            defaultFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        }
        let measure = ("W" as NSString).size(withAttributes: [.font: defaultFont])
        cellWidth = ceil(measure.width)
        cellHeight = ceil(measure.height)
        paddingBottom = cellHeight
        bgColor = Self.loadColor(forKey: "terminalBGColor") ?? ThemeManager.shared.terminalBG
        fgColor = Self.loadColor(forKey: "terminalFGColor") ?? ThemeManager.shared.terminalFG
        super.init(frame: frame)
        updateLineNumberLayout()
        updateTimestampLayout()

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyTheme() }
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        blinkTimer?.invalidate()
        if let o = themeObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func applyTheme() {
        let tm = ThemeManager.shared
        // Only update if the user hasn't customized colors
        if Self.loadColor(forKey: "terminalBGColor") == nil {
            bgColor = tm.terminalBG
        }
        if Self.loadColor(forKey: "terminalFGColor") == nil {
            fgColor = tm.terminalFG
        }
        // Update scroll view background
        if let sv = superview as? NSClipView,
           let scrollView = sv.superview as? NSScrollView {
            scrollView.backgroundColor = bgColor
        }
        needsDisplay = true
    }

    func updateTimestampLayout() {
        if showTimestamp {
            let sample = ("00:00:00" as NSString)
            let tsFont = NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize - 2, weight: .regular)
            timestampWidth = ceil(sample.size(withAttributes: [.font: tsFont]).width) + 8
        } else {
            timestampWidth = 0
        }
        paddingLeft = Self.basePaddingLeft + lineNumberWidth
    }

    func setTimestampVisible(_ visible: Bool) {
        showTimestamp = visible
        UserDefaults.standard.set(visible, forKey: "showTimestamp")
        updateTimestampLayout()
        triggerRelayout()
    }

    func updateLineNumberLayout() {
        if showLineNumber {
            let sample = ("99999" as NSString)
            let lnFont = NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize - 2, weight: .regular)
            lineNumberWidth = ceil(sample.size(withAttributes: [.font: lnFont]).width) + 8
        } else {
            lineNumberWidth = 0
        }
        paddingLeft = Self.basePaddingLeft + lineNumberWidth
    }

    func setLineNumberVisible(_ visible: Bool) {
        showLineNumber = visible
        UserDefaults.standard.set(visible, forKey: "showLineNumber")
        updateLineNumberLayout()
        updateTimestampLayout()
        triggerRelayout()
    }

    private func triggerRelayout() {
        if let sv = superview as? NSClipView,
           let container = sv.superview?.superview as? TerminalContainerView {
            container.lastCols = 0; container.lastRows = 0
            container.layout()
            container.refreshDisplay()
        }
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else { return false }

        let paths = items.map { path in
            let p = path.path.precomposedStringWithCanonicalMapping
            return p.contains(" ") ? "\"\(p)\"" : p
        }
        terminal?.write(paths.joined(separator: " "))
        return true
    }

    // MARK: - Persistence Helpers

    private static func loadColor(forKey key: String) -> NSColor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private static func saveColor(_ color: NSColor, forKey key: String) {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Font / Color Actions

    @objc func showFontPanel(_ sender: Any?) {
        let panel = NSFontPanel.shared
        NSFontManager.shared.setSelectedFont(defaultFont, isMultiple: false)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func showBGColorPanel(_ sender: Any?) {
        colorEditTarget = .background
        let panel = NSColorPanel.shared
        panel.color = bgColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func showFGColorPanel(_ sender: Any?) {
        colorEditTarget = .foreground
        let panel = NSColorPanel.shared
        panel.color = fgColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        let color = sender.color
        switch colorEditTarget {
        case .background:
            bgColor = color
            Self.saveColor(color, forKey: "terminalBGColor")
            // Update scroll view background
            if let sv = superview as? NSClipView,
               let scrollView = sv.superview as? NSScrollView {
                scrollView.backgroundColor = color
            }
        case .foreground:
            fgColor = color
            Self.saveColor(color, forKey: "terminalFGColor")
        }
        needsDisplay = true
    }

    @objc func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { return }
        let newFont = manager.convert(defaultFont)
        defaultFont = newFont
        boldFont = manager.convert(newFont, toHaveTrait: .boldFontMask)
        let measure = ("W" as NSString).size(withAttributes: [.font: newFont])
        cellWidth = ceil(measure.width)
        cellHeight = ceil(measure.height)
        paddingBottom = cellHeight

        UserDefaults.standard.set(newFont.fontName, forKey: "terminalFontName")
        UserDefaults.standard.set(Double(newFont.pointSize), forKey: "terminalFontSize")

        updateLineNumberLayout()
        updateTimestampLayout()
        triggerRelayout()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.deltaY
            guard abs(delta) > 0.1 else { return }
            let currentSize = defaultFont.pointSize
            let newSize = max(8, min(72, currentSize + (delta > 0 ? -1 : 1)))
            guard newSize != currentSize else { return }
            applyFontSize(newSize)
            return
        }
        super.scrollWheel(with: event)
    }

    private func applyFontSize(_ size: CGFloat) {
        if let name = UserDefaults.standard.string(forKey: "terminalFontName"),
           let f = NSFont(name: name, size: size) {
            defaultFont = f
            boldFont = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        } else {
            defaultFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
        let measure = ("W" as NSString).size(withAttributes: [.font: defaultFont])
        cellWidth = ceil(measure.width)
        cellHeight = ceil(measure.height)
        paddingBottom = cellHeight

        UserDefaults.standard.set(defaultFont.fontName, forKey: "terminalFontName")
        UserDefaults.standard.set(Double(size), forKey: "terminalFontSize")

        updateLineNumberLayout()
        updateTimestampLayout()
        triggerRelayout()
    }

    @objc func resetToDefaults(_ sender: Any?) {
        // Reset font
        let size: CGFloat = 13
        defaultFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let measure = ("W" as NSString).size(withAttributes: [.font: defaultFont])
        cellWidth = ceil(measure.width)
        cellHeight = ceil(measure.height)
        paddingBottom = cellHeight
        UserDefaults.standard.removeObject(forKey: "terminalFontName")
        UserDefaults.standard.removeObject(forKey: "terminalFontSize")

        // Reset colors
        bgColor = ThemeManager.shared.terminalBG
        fgColor = ThemeManager.shared.terminalFG
        UserDefaults.standard.removeObject(forKey: "terminalBGColor")
        UserDefaults.standard.removeObject(forKey: "terminalFGColor")

        // Update scroll view background
        if let sv = superview as? NSClipView,
           let scrollView = sv.superview as? NSScrollView {
            scrollView.backgroundColor = bgColor
        }

        updateLineNumberLayout()
        updateTimestampLayout()
        triggerRelayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.cursorOn.toggle()
                self?.needsDisplay = true
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let screen = screen else { return }

        bgColor.setFill()
        dirtyRect.fill()

        let sbCount = screen.scrollback.count
        let totalLines = sbCount + screen.rows
        let firstLine = max(0, Int(floor(dirtyRect.minY / cellHeight)))
        let lastLine = min(totalLines - 1, Int(ceil(dirtyRect.maxY / cellHeight)))
        guard firstLine <= lastLine else { return }

        // Helper to check if a physical line is a wrapped continuation
        let isWrapped: (Int) -> Bool = { idx in
            if idx < sbCount {
                return idx < screen.scrollbackWrapped.count && screen.scrollbackWrapped[idx]
            } else {
                let sr = idx - sbCount
                return sr < screen.gridWrapped.count && screen.gridWrapped[sr]
            }
        }

        // Pre-compute logical line number at firstLine
        var logicalLine = 0
        if showLineNumber || showTimestamp {
            for i in 0..<firstLine {
                if !isWrapped(i) { logicalLine += 1 }
            }
        }

        for lineIdx in firstLine...lastLine {
            let y = CGFloat(lineIdx) * cellHeight

            // Track logical line number
            if (showLineNumber || showTimestamp) && !isWrapped(lineIdx) {
                logicalLine += 1
            }

            let cells: [TerminalScreen.Cell]
            let screenRow: Int

            if lineIdx < sbCount {
                cells = screen.scrollback[lineIdx]
                screenRow = -1
            } else {
                screenRow = lineIdx - sbCount
                guard screenRow < screen.rows else { continue }
                cells = screen.grid[screenRow]
            }

            var col = 0
            while col < cells.count && col < screen.cols {
                let cell = cells[col]

                // Skip padding cells (second half of wide char)
                if cell.widePadding {
                    col += 1
                    continue
                }

                let x = CGFloat(col) * cellWidth + paddingLeft
                let drawWidth = cell.wide ? cellWidth * 2 : cellWidth
                let rect = NSRect(x: x, y: y, width: drawWidth, height: cellHeight)

                let isCursor = screenRow >= 0
                    && screenRow == screen.cursorRow
                    && col == screen.cursorCol
                    && screen.showCursor && cursorOn
                let isSel = isCellSelected(line: lineIdx, col: col)
                let matchType = searchMatchType(line: lineIdx, col: col)

                // Background
                var bg = bgColor
                if matchType == 2 {
                    bg = NSColor.systemOrange
                } else if matchType == 1 {
                    bg = NSColor.systemYellow.withAlphaComponent(0.4)
                } else if isSel {
                    bg = .selectedTextBackgroundColor
                } else if isCursor {
                    bg = ThemeManager.shared.cursorColor
                } else if cell.bg != .clear {
                    bg = cell.bg
                }

                if bg != bgColor {
                    bg.setFill()
                    rect.fill()
                }

                // Character
                let ch = cell.char
                if (ch == " " && !isCursor) || cell.invisible {
                    col += cell.wide ? 2 : 1
                    continue
                }

                var fg: NSColor
                if isCursor { fg = ThemeManager.shared.cursorTextColor }
                else if isSel { fg = .white }
                else { fg = (cell.fg == TerminalScreen.defaultFG) ? fgColor : cell.fg }

                if cell.dim {
                    fg = fg.withAlphaComponent(0.5)
                }

                var font: NSFont
                if cell.bold && cell.italic {
                    font = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
                } else if cell.italic {
                    font = NSFontManager.shared.convert(defaultFont, toHaveTrait: .italicFontMask)
                } else if cell.bold {
                    font = boldFont
                } else {
                    font = defaultFont
                }

                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: fg,
                ]
                if cell.underline {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if cell.strikethrough {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }

                let s = NSAttributedString(string: String(ch), attributes: attrs)
                s.draw(at: NSPoint(x: x, y: y))

                col += cell.wide ? 2 : 1
            }

            // Check if this is the last physical line of a logical line group
            let isLastOfGroup = (lineIdx + 1 >= totalLines) || !isWrapped(lineIdx + 1)

            let hasContent = cells.prefix(min(cells.count, screen.cols)).contains { c in
                !c.widePadding && c.char != " "
            }

            // Draw line number on the left side (last line of group, non-empty only)
            if showLineNumber && isLastOfGroup && hasContent {
                let lnStr = "\(logicalLine)" as NSString
                let lnFont = NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize - 2, weight: .regular)
                let lnColor = ThemeManager.shared.statusBarText
                let lnAttrs: [NSAttributedString.Key: Any] = [
                    .font: lnFont,
                    .foregroundColor: lnColor,
                ]
                let lnSize = lnStr.size(withAttributes: lnAttrs)
                let lnX = Self.basePaddingLeft + lineNumberWidth - lnSize.width - 4
                let lnY = y + (cellHeight - lnFont.pointSize) / 2 - 1
                lnStr.draw(at: NSPoint(x: lnX, y: lnY), withAttributes: lnAttrs)
            }

            // Draw timestamp on the right side (last line of group, non-empty only)
            if showTimestamp && isLastOfGroup && hasContent {
                let ts: Date
                if lineIdx < sbCount {
                    ts = lineIdx < screen.scrollbackTimestamps.count
                        ? screen.scrollbackTimestamps[lineIdx] : Date()
                } else {
                    let sr = lineIdx - sbCount
                    ts = sr < screen.gridTimestamps.count
                        ? screen.gridTimestamps[sr] : Date()
                }
                let tsStr = timestampFormatter.string(from: ts) as NSString
                let tsFont = NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize - 2, weight: .regular)
                let tsColor = ThemeManager.shared.statusBarText
                let tsAttrs: [NSAttributedString.Key: Any] = [
                    .font: tsFont,
                    .foregroundColor: tsColor,
                ]
                let tsX = bounds.width - timestampWidth
                let tsY = y + (cellHeight - tsFont.pointSize) / 2 - 1
                tsStr.draw(at: NSPoint(x: tsX, y: tsY), withAttributes: tsAttrs)
            }
        }

        // Draw IME marked text overlay
        if let marked = markedString, !marked.isEmpty {
            drawMarkedText(marked)
        }
    }

    private func drawMarkedText(_ text: String) {
        guard let screen = screen else { return }
        let sbCount = screen.scrollback.count
        let x = CGFloat(screen.cursorCol) * cellWidth + paddingLeft
        let y = CGFloat(sbCount + screen.cursorRow) * cellHeight

        let tm = ThemeManager.shared
        let attrs: [NSAttributedString.Key: Any] = [
            .font: defaultFont,
            .foregroundColor: tm.markedTextFG,
            .backgroundColor: tm.markedTextBG,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        attrStr.draw(at: NSPoint(x: x, y: y))
    }

    // MARK: - Selection

    private func searchMatchType(line: Int, col: Int) -> Int {
        // Returns: 0 = no match, 1 = match, 2 = current match
        for (i, m) in searchMatches.enumerated() {
            if m.line == line && col >= m.col && col < m.col + m.length {
                return i == currentMatchIndex ? 2 : 1
            }
        }
        return 0
    }

    private func isCellSelected(line: Int, col: Int) -> Bool {
        guard let s0 = selStart, let s1 = selEnd else { return false }
        let a = (s0.row < s1.row || (s0.row == s1.row && s0.col <= s1.col)) ? s0 : s1
        let b = (s0.row < s1.row || (s0.row == s1.row && s0.col <= s1.col)) ? s1 : s0
        if line < a.row || line > b.row { return false }

        switch selectionMode {
        case .line:
            if line == a.row && line == b.row { return col >= a.col && col <= b.col }
            if line == a.row { return col >= a.col }
            if line == b.row { return col <= b.col }
            return true
        case .block:
            let minCol = min(s0.col, s1.col)
            let maxCol = max(s0.col, s1.col)
            return col >= minCol && col <= maxCol
        }
    }

    private func pointToCell(_ pt: NSPoint) -> (row: Int, col: Int) {
        let total = (screen?.scrollback.count ?? 0) + (screen?.rows ?? 0)
        let row = max(0, min(Int(pt.y / cellHeight), total - 1))
        let col = max(0, min(Int((pt.x - paddingLeft) / cellWidth), (screen?.cols ?? 1) - 1))
        return (row, col)
    }

    private func copySelection() {
        guard let screen = screen, let s0 = selStart, let s1 = selEnd else { return }
        let a = (s0.row < s1.row || (s0.row == s1.row && s0.col <= s1.col)) ? s0 : s1
        let b = (s0.row < s1.row || (s0.row == s1.row && s0.col <= s1.col)) ? s1 : s0

        var text = ""
        for line in a.row...b.row {
            let cells: [TerminalScreen.Cell]
            if line < screen.scrollback.count {
                cells = screen.scrollback[line]
            } else {
                let sr = line - screen.scrollback.count
                guard sr < screen.rows else { continue }
                cells = screen.grid[sr]
            }

            let c0: Int
            let c1: Int
            switch selectionMode {
            case .line:
                c0 = (line == a.row) ? a.col : 0
                c1 = (line == b.row) ? min(b.col, cells.count - 1) : cells.count - 1
            case .block:
                c0 = min(s0.col, s1.col)
                c1 = min(max(s0.col, s1.col), cells.count - 1)
            }

            var lineText = ""
            for c in c0...c1 {
                if cells[c].widePadding { continue }
                lineText.append(cells[c].char)
            }
            while lineText.hasSuffix(" ") { lineText.removeLast() }
            text += lineText
            if line < b.row { text += "\n" }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        cursorOn = true

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) {
            if let chars = event.charactersIgnoringModifiers,
               let ch = chars.first, let a = ch.asciiValue {
                screen?.inputBuffer = ""
                terminal?.write(String(UnicodeScalar(a & 0x1f)))
                return
            }
        }

        let appCursor = screen?.applicationCursorKeys ?? false
        let pre = appCursor ? "\u{1b}O" : "\u{1b}["

        switch event.keyCode {
        case 36:
            let cmd = screen?.inputBuffer.trimmingCharacters(in: .whitespaces) ?? ""
            if !cmd.isEmpty { screen?.onCommandEntered?(cmd) }
            screen?.inputBuffer = ""
            terminal?.write("\r")
        case 51:
            if let buf = screen?.inputBuffer, !buf.isEmpty {
                screen?.inputBuffer = String(buf.dropLast())
            }
            terminal?.write("\u{7f}")
        case 48:  terminal?.write("\t")
        case 53:
            if let sv = superview as? NSClipView,
               let container = sv.superview?.superview as? TerminalContainerView,
               container.isFindBarVisible {
                container.toggleFindBar(show: false)
                return
            }
            terminal?.write("\u{1b}")
        case 123: terminal?.write("\(pre)D")
        case 124: terminal?.write("\(pre)C")
        case 125: terminal?.write("\(pre)B")
        case 126: terminal?.write("\(pre)A")
        case 115: terminal?.write("\u{1b}[H")
        case 119: terminal?.write("\u{1b}[F")
        case 116: terminal?.write("\u{1b}[5~")
        case 121: terminal?.write("\u{1b}[6~")
        case 117: terminal?.write("\u{1b}[3~")
        default:
            // Route through IME for text composition (Korean, Japanese, etc.)
            inputContext?.handleEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let chars = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == .command {
            switch chars {
            case "c":
                if selStart != nil, selEnd != nil { copySelection(); return true }
                return false
            case "v":
                if let s = NSPasteboard.general.string(forType: .string)?.precomposedStringWithCanonicalMapping {
                    if screen?.bracketedPasteMode == true {
                        terminal?.write("\u{1b}[200~")
                        terminal?.write(s)
                        terminal?.write("\u{1b}[201~")
                    } else {
                        terminal?.write(s)
                    }
                }
                return true
            case "f":
                if let sv = superview as? NSClipView, let container = sv.superview?.superview as? TerminalContainerView {
                    container.toggleFindBar(show: !container.isFindBarVisible)
                }
                return true
            case "k":
                screen?.scrollback.removeAll()
                screen?.scrollbackTimestamps.removeAll()
                if let sv = superview as? NSClipView, let container = sv.superview?.superview as? TerminalContainerView {
                    container.refreshDisplay()
                }
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Edit Menu Actions

    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    @objc func paste(_ sender: Any?) {
        if let s = NSPasteboard.general.string(forType: .string)?.precomposedStringWithCanonicalMapping {
            if screen?.bracketedPasteMode == true {
                terminal?.write("\u{1b}[200~")
                terminal?.write(s)
                terminal?.write("\u{1b}[201~")
            } else {
                terminal?.write(s)
            }
        }
    }

    override func selectAll(_ sender: Any?) {
        guard let screen = screen else { return }
        let totalLines = screen.scrollback.count + screen.rows
        selStart = (row: 0, col: 0)
        selEnd = (row: totalLines - 1, col: screen.cols - 1)
        onSelectionChange?((start: selStart!, end: selEnd!))
        needsDisplay = true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return selStart != nil && selEnd != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            return true
        default:
            return super.responds(to: item.action)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocused?()

        if event.clickCount == 2 {
            let cell = pointToCell(convert(event.locationInWindow, from: nil))
            if let range = findWordRange(at: cell) {
                selectionMode = .line
                selStart = (row: cell.row, col: range.start)
                selEnd = (row: cell.row, col: range.end)
                onSelectionChange?((start: selStart!, end: selEnd!))
                needsDisplay = true
                return
            }
        }

        if event.modifierFlags.contains(.command) {
            selectionMode = .block
        } else {
            selectionMode = UserDefaults.standard.bool(forKey: "blockSelectionMode") ? .block : .line
        }
        selStart = pointToCell(convert(event.locationInWindow, from: nil))
        selEnd = nil
        onSelectionChange?(nil)
        needsDisplay = true
    }

    private func findWordRange(at cell: (row: Int, col: Int)) -> (start: Int, end: Int)? {
        guard let screen = screen else { return nil }
        let sbCount = screen.scrollback.count
        let cells: [TerminalScreen.Cell]
        if cell.row < sbCount {
            cells = screen.scrollback[cell.row]
        } else {
            let sr = cell.row - sbCount
            guard sr >= 0, sr < screen.rows else { return nil }
            cells = screen.grid[sr]
        }
        let cols = screen.cols
        guard cell.col >= 0, cell.col < cols else { return nil }

        // If clicked on a space, no selection
        if cells[cell.col].char == " " { return nil }

        // Scan left: find boundary (2+ consecutive spaces or line start)
        var start = cell.col
        while start > 0 {
            if start >= 2 && cells[start - 1].char == " " && cells[start - 2].char == " " {
                break
            }
            if start >= 1 && cells[start - 1].char == " " {
                // Check if this single space is part of 2+ spaces
                if start >= 2 && cells[start - 2].char == " " {
                    break
                }
                // Single space — include it in selection, keep scanning
                start -= 1
            } else {
                start -= 1
            }
        }

        // Scan right: find boundary (2+ consecutive spaces or line end)
        var end = cell.col
        while end < cols - 1 {
            if end + 2 < cols && cells[end + 1].char == " " && cells[end + 2].char == " " {
                break
            }
            if end + 1 < cols && cells[end + 1].char == " " {
                if end + 2 < cols && cells[end + 2].char == " " {
                    break
                }
                end += 1
            } else {
                end += 1
            }
        }

        // Trim leading/trailing single spaces from selection
        while start < end && cells[start].char == " " { start += 1 }
        while end > start && cells[end].char == " " { end -= 1 }

        return (start: start, end: end)
    }

    override func mouseDragged(with event: NSEvent) {
        selEnd = pointToCell(convert(event.locationInWindow, from: nil))
        if let s = selStart, let e = selEnd {
            onSelectionChange?((start: s, end: e))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if selEnd == nil {
            selStart = nil
            onSelectionChange?(nil)
            needsDisplay = true
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if selStart != nil, selEnd != nil {
            // Selection exists → copy
            copySelection()
            selStart = nil
            selEnd = nil
            onSelectionChange?(nil)
            needsDisplay = true
        } else {
            // No selection → paste
            if let s = NSPasteboard.general.string(forType: .string)?.precomposedStringWithCanonicalMapping {
                if screen?.bracketedPasteMode == true {
                    terminal?.write("\u{1b}[200~")
                    terminal?.write(s)
                    terminal?.write("\u{1b}[201~")
                } else {
                    terminal?.write(s)
                }
            }
        }
    }
}

// MARK: - NSTextInputClient (IME Support)

extension TerminalDrawView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        let str: String
        if let s = string as? String { str = s }
        else if let s = string as? NSAttributedString { str = s.string }
        else { return }

        markedString = nil
        screen?.inputBuffer += str
        terminal?.write(str)
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? String { markedString = s }
        else if let s = string as? NSAttributedString { markedString = s.string }
        needsDisplay = true
    }

    func unmarkText() {
        markedString = nil
        needsDisplay = true
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        if let m = markedString, !m.isEmpty {
            return NSRange(location: 0, length: m.utf16.count)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedString != nil && !(markedString?.isEmpty ?? true)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor, .backgroundColor, .underlineStyle]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let screen = screen, let win = window else { return .zero }
        let sbCount = screen.scrollback.count
        let x = CGFloat(screen.cursorCol) * cellWidth + paddingLeft
        let y = CGFloat(sbCount + screen.cursorRow) * cellHeight
        let rectInView = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
        let rectInWindow = convert(rectInView, to: nil)
        return win.convertToScreen(rectInWindow)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }
}

// MARK: - Status Bar

class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var themeObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyTheme()

        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = themeObserver { NotificationCenter.default.removeObserver(o) } }

    private func applyTheme() {
        let tm = ThemeManager.shared
        layer?.backgroundColor = tm.statusBarBG.cgColor
        label.textColor = tm.statusBarText
    }

    func update(_ text: String) {
        label.stringValue = text
    }
}

// MARK: - Color

extension NSColor {
    static var terminalBG: NSColor { ThemeManager.shared.terminalBG }
}
