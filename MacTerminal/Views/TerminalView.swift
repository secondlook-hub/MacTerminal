import SwiftUI
import AppKit
import QuartzCore

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
    /// Reported column count in no-wrap mode. Large enough that real-world lines
    /// (wide tables, long paths) almost never wrap, but far below the old 10000:
    /// every grid/scrollback row allocates this many Cells, and a fresh blank row
    /// of this width is allocated on every line scroll.
    static let noWrapCols = 1000
    private var findBarTop: NSLayoutConstraint!
    private var scrollViewTop: NSLayoutConstraint!
    private(set) var isFindBarVisible = false
    var textWrap = UserDefaults.standard.object(forKey: "textWrap") == nil ? true : UserDefaults.standard.bool(forKey: "textWrap")
    var onFocused: (() -> Void)?
    private(set) weak var currentPane: TerminalPane?

    // Display refresh throttling. Bursty PTY output (`cat largefile`, `npm install`)
    // can request a refresh hundreds of times per runloop turn; the heavy work
    // (frame resize, clip scroll, reflect, status bar) is pointless faster than
    // the screen actually refreshes. Cap to ~display rate with a guaranteed
    // trailing refresh so the final frame is always shown.
    private var refreshThrottleScheduled = false
    private var lastRefreshAt: CFTimeInterval = 0
    private static let minRefreshInterval: CFTimeInterval = 1.0 / 120.0

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
        scrollView.hasHorizontalScroller = !textWrap
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
        // Scrollback portion is maintained incrementally (see TerminalScreen) so
        // this stays O(visible rows) instead of O(scrollback) on every refresh.
        var logicalLine = screen.scrollbackLogicalLines
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
        currentPane = pane
        pane.onScreenUpdate = { [weak self] in
            self?.refreshDisplay()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-bind when this container is added to a (new) window.
        // This ensures onScreenUpdate points to the live container after
        // detach/reattach, where the old container may have overwritten it.
        if window != nil, let pane = currentPane {
            pane.onScreenUpdate = { [weak self] in
                self?.refreshDisplay()
            }
            refreshDisplay()
        }
    }

    func refreshDisplay() {
        // Background (hidden) tabs do no view work at all: AppKit won't draw a
        // hidden view anyway, and the frame/scroll/status-bar churn just steals
        // the main thread from the visible tab. The host re-runs refreshDisplay()
        // when the tab is revealed, and viewDidMoveToWindow does on attach, so
        // the visible state is always brought current at that point.
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }

        let now = CACurrentMediaTime()
        let elapsed = now - lastRefreshAt
        if elapsed < Self.minRefreshInterval {
            // Too soon — schedule a single trailing refresh and coalesce the rest.
            guard !refreshThrottleScheduled else { return }
            refreshThrottleScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.minRefreshInterval - elapsed)) { [weak self] in
                guard let self = self else { return }
                self.refreshThrottleScheduled = false
                self.refreshDisplay()
            }
            return
        }
        lastRefreshAt = now
        performRefresh()
    }

    private func performRefresh() {
        let totalLines = screen.scrollback.count + screen.rows
        let contentHeight = CGFloat(totalLines) * drawView.cellHeight + drawView.paddingBottom
        let height = max(contentHeight, scrollView.contentSize.height)
        let width: CGFloat
        if textWrap {
            width = scrollView.contentSize.width
        } else {
            let contentWidth = drawView.paddingLeft + CGFloat(screen.cols) * drawView.cellWidth + drawView.timestampWidth
            width = max(contentWidth, scrollView.contentSize.width)
        }

        drawView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Auto-scroll to bottom
        let clipView = scrollView.contentView
        let maxY = max(0, height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(clipView)

        // Invalidate only the viewport, not the whole document. The document view
        // is as tall as the entire scrollback (thousands of rows); marking it all
        // dirty makes a layer-backed view re-render a backing store proportional to
        // scrollback length on every refresh — the slowdown that appears once the
        // scrollback has filled. Only the visible rows are ever shown, so redraw
        // cost stays O(viewport) regardless of how long the scrollback gets.
        drawView.setNeedsDisplay(drawView.visibleRect)

        updateStatusBar()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let availableHeight = bounds.height - Self.statusBarHeight
        let cols: Int
        if textWrap {
            let availableWidth = bounds.width - drawView.paddingLeft - drawView.timestampWidth
            cols = max(Int(availableWidth / drawView.cellWidth), 20)
        } else {
            cols = Self.noWrapCols
        }
        let rows = max(Int((availableHeight - drawView.paddingBottom) / drawView.cellHeight), 5)

        if cols != lastCols || rows != lastRows {
            lastCols = cols; lastRows = rows
            screen.resize(newRows: rows, newCols: cols)
            terminal.resize(cols: UInt16(cols), rows: UInt16(rows))
            refreshDisplay()
        }
    }

    func setTextWrap(_ enabled: Bool) {
        textWrap = enabled
        UserDefaults.standard.set(enabled, forKey: "textWrap")
        scrollView.hasHorizontalScroller = !enabled
        lastCols = 0; lastRows = 0
        layout()
        refreshDisplay()
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
    var defaultFont: NSFont {
        didSet { italicFont = nil; boldItalicFont = nil; resetTextCaches() }
    }
    var boldFont: NSFont {
        didSet { boldItalicFont = nil; resetTextCaches() }
    }
    // Lazy variants: NSFontManager.convert is surprisingly hot when scrollback
    // is full of styled output (CI logs, syntax-highlighted source). Cache them.
    private var italicFont: NSFont?
    private var boldItalicFont: NSFont?

    private func styledFont(bold: Bool, italic: Bool) -> NSFont {
        switch (bold, italic) {
        case (false, false): return defaultFont
        case (true, false):  return boldFont
        case (false, true):
            if let f = italicFont { return f }
            let f = NSFontManager.shared.convert(defaultFont, toHaveTrait: .italicFontMask)
            italicFont = f
            return f
        case (true, true):
            if let f = boldItalicFont { return f }
            let f = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
            boldItalicFont = f
            return f
        }
    }
    private static func styleIndex(bold: Bool, italic: Bool) -> UInt8 {
        (bold ? 1 : 0) | (italic ? 2 : 0)
    }

    private func styledFont(style: UInt8) -> NSFont {
        styledFont(bold: style & 1 != 0, italic: style & 2 != 0)
    }

    // MARK: - Glyph cache
    //
    // The draw loop used to call NSString.draw(at:withAttributes:) once per
    // character. That spins up the whole TextKit string-drawing engine —
    // typesetter, line-metric measurement, attribute-dictionary bridging — to
    // put a single glyph on screen. Blank cells are skipped, so a fresh session
    // is cheap and the cost only shows up once enough text is on screen: the
    // "it gets slower the longer I use it" symptom. Sampling a long-running
    // session put 92% of main-thread work in draw(_:), nearly all of it inside
    // __NSStringDrawingEngine. Core Text with cached glyph ids draws a whole run
    // of same-styled cells in one call instead, and the per-character work drops
    // to a dictionary lookup.

    private struct TextKey: Hashable {
        let style: UInt8
        let ch: Character
    }
    /// Glyph id per character and style. `0` means the styled font has no glyph
    /// for it (CJK, emoji, some box-drawing) — those go through `fallbackLine`
    /// so Core Text can run its own font fallback.
    private var glyphCache: [TextKey: CGGlyph] = [:]
    private var fallbackLineCache: [TextKey: CTLine] = [:]
    /// Distance from the top of a cell down to the text baseline, per style.
    /// Taken from the same layout manager NSStringDrawing uses, so glyphs land
    /// exactly where they did before.
    private var baselineCache: [UInt8: CGFloat] = [:]
    private var gutterTextCache: [String: (line: CTLine, width: CGFloat)] = [:]
    private static let baselineLayoutManager = NSLayoutManager()
    /// Distinct characters in a session are bounded in practice, but a stream of
    /// CJK or emoji could grow these without limit. Drop everything at a
    /// generous ceiling rather than track ages — a refill is a few microseconds.
    private static let textCacheLimit = 8192

    private func resetTextCaches() {
        glyphCache.removeAll(keepingCapacity: true)
        fallbackLineCache.removeAll(keepingCapacity: true)
        baselineCache.removeAll(keepingCapacity: true)
        gutterTextCache.removeAll(keepingCapacity: true)
    }

    private func baseline(forStyle style: UInt8) -> CGFloat {
        if let b = baselineCache[style] { return b }
        let b = Self.baselineLayoutManager.defaultBaselineOffset(for: styledFont(style: style))
        baselineCache[style] = b
        return b
    }

    /// Glyph id for `ch`, or 0 when the styled font cannot render it.
    private func glyph(for ch: Character, style: UInt8) -> CGGlyph {
        let key = TextKey(style: style, ch: ch)
        if let g = glyphCache[key] { return g }
        var glyph: CGGlyph = 0
        // Only single-UTF16-unit characters take the fast path: the Core Text
        // call maps code units, not grapheme clusters, so surrogate pairs and
        // combining sequences would come out wrong.
        let scalars = ch.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first, scalar.value <= 0xFFFF {
            var unit = UniChar(scalar.value)
            var out: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(styledFont(style: style) as CTFont, &unit, &out, 1) {
                glyph = out
            }
        }
        if glyphCache.count >= Self.textCacheLimit { glyphCache.removeAll(keepingCapacity: true) }
        glyphCache[key] = glyph
        return glyph
    }

    /// Cached single-character line for what the styled font can't draw itself.
    /// Deliberately carries no foreground colour: CTLineDraw then paints with
    /// the context fill colour, so one cached line serves every colour the cell
    /// may take.
    private func fallbackLine(for ch: Character, style: UInt8) -> CTLine {
        let key = TextKey(style: style, ch: ch)
        if let l = fallbackLineCache[key] { return l }
        let attr = NSAttributedString(string: String(ch),
                                      attributes: [.font: styledFont(style: style)])
        let line = CTLineCreateWithAttributedString(attr)
        if fallbackLineCache.count >= Self.textCacheLimit {
            fallbackLineCache.removeAll(keepingCapacity: true)
        }
        fallbackLineCache[key] = line
        return line
    }

    /// Cached gutter line (line number / timestamp) plus its measured width.
    /// These repeat heavily — a timestamp changes once a second, line numbers
    /// scroll through a small window — so measuring and typesetting them per
    /// frame was pure waste.
    private func gutterText(_ s: String) -> (line: CTLine, width: CGFloat) {
        if let c = gutterTextCache[s] { return c }
        let attr = NSAttributedString(string: s, attributes: [.font: gutterFont!])
        let line = CTLineCreateWithAttributedString(attr)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if gutterTextCache.count >= Self.textCacheLimit {
            gutterTextCache.removeAll(keepingCapacity: true)
        }
        let entry = (line: line, width: width)
        gutterTextCache[s] = entry
        return entry
    }

    // MARK: - Glyph run batching
    //
    // Consecutive cells sharing a font and colour are collected and drawn in one
    // CTFontDrawGlyphs call. The run is flushed at the end of each row, which
    // also means every glyph in a row lands *after* every background fill in
    // that row — a glyph that overhangs its cell (italics) is no longer clipped
    // by the next cell's background.

    private var runGlyphs: [CGGlyph] = []
    private var runPositions: [CGPoint] = []
    private var runFont: NSFont?
    private var runColor: NSColor?
    private var runBaselineY: CGFloat = 0
    /// Cells the styled font can't draw, held back to the end of the row for the
    /// same ordering reason.
    private var runFallbacks: [(line: CTLine, x: CGFloat, baselineY: CGFloat, color: NSColor)] = []

    private func appendGlyph(_ g: CGGlyph, x: CGFloat, font: NSFont, color: NSColor,
                             baselineY: CGFloat, in ctx: CGContext) {
        if runFont !== font || runBaselineY != baselineY
            || !(runColor === color || runColor == color) {
            flushRowText(in: ctx)
            runFont = font
            runColor = color
            runBaselineY = baselineY
        }
        runGlyphs.append(g)
        // Positions are relative to the run's baseline; flushRowText translates
        // the context there before drawing.
        runPositions.append(CGPoint(x: x, y: 0))
    }

    private func flushRowText(in ctx: CGContext) {
        if !runGlyphs.isEmpty, let font = runFont, let color = runColor {
            ctx.saveGState()
            ctx.textMatrix = .identity
            // The view is flipped; flipping back here draws the glyphs upright
            // and puts the run's baseline at y = 0.
            ctx.translateBy(x: 0, y: runBaselineY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(color.cgColor)
            CTFontDrawGlyphs(font as CTFont, runGlyphs, runPositions, runGlyphs.count, ctx)
            ctx.restoreGState()
        }
        runGlyphs.removeAll(keepingCapacity: true)
        runPositions.removeAll(keepingCapacity: true)
        runFont = nil
        runColor = nil

        for f in runFallbacks {
            drawLine(f.line, x: f.x, baselineY: f.baselineY, color: f.color, in: ctx)
        }
        runFallbacks.removeAll(keepingCapacity: true)
    }

    private func drawLine(_ line: CTLine, x: CGFloat, baselineY: CGFloat,
                          color: NSColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(color.cgColor)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // Gutter (line number / timestamp) rendering cache. Both gutters share one
    // font (2pt smaller than the body font) and the status-bar text color, and
    // their typeset lines are cached by string in `gutterTextCache`. Refresh
    // only on font / theme changes.
    private var gutterFont: NSFont!
    private var gutterBaseline: CGFloat = 0
    private func rebuildGutterCache() {
        gutterFont = NSFont.monospacedSystemFont(ofSize: defaultFont.pointSize - 2, weight: .regular)
        gutterBaseline = Self.baselineLayoutManager.defaultBaselineOffset(for: gutterFont)
        gutterTextCache.removeAll(keepingCapacity: true)
    }

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
    /// Cell of the previous mouseDown, used to gate double-click word selection:
    /// macOS reports clickCount==2 purely on timing, so two quick clicks made to
    /// *reposition* (different spots) would select a word. We only treat it as a
    /// word double-click when the second click lands on essentially the same cell.
    private var lastClickCell: (row: Int, col: Int)?

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
    private var isBackspacingComposition = false

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
        rebuildGutterCache()
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
        rebuildGutterCache()
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

    @objc func increaseFontSize(_ sender: Any?) {
        let newSize = min(72, defaultFont.pointSize + 1)
        guard newSize != defaultFont.pointSize else { return }
        applyFontSize(newSize)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        let newSize = max(8, defaultFont.pointSize - 1)
        guard newSize != defaultFont.pointSize else { return }
        applyFontSize(newSize)
    }

    @objc func resetFontSize(_ sender: Any?) {
        applyFontSize(13)
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
        if window == nil {
            // View is being detached — stop the timer so it doesn't keep firing
            // (and holding allocations) for invisible/torn-down panes.
            blinkTimer?.invalidate()
            blinkTimer = nil
        } else if blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // Skip work when the window isn't key — the cursor is rendered
                // hollow and the screen isn't visible, so toggling state just burns CPU.
                guard self.window?.isKeyWindow == true else { return }
                self.cursorOn.toggle()
                self.invalidateCursorCell()
            }
        }
    }

    /// Mark only the cursor cell as needing redraw. The blink toggles every 500ms;
    /// invalidating the entire visible area on every tick churns NSAttributedString
    /// allocations and creates measurable memory pressure over hours.
    private func invalidateCursorCell() {
        guard let screen = screen else { return }
        let row = screen.scrollback.count + screen.cursorRow
        let x = CGFloat(screen.cursorCol) * cellWidth + paddingLeft
        let y = CGFloat(row) * cellHeight
        // Width = 2 cells in case a wide character sits under the cursor.
        let rect = NSRect(x: x, y: y, width: cellWidth * 2, height: cellHeight)
        setNeedsDisplay(rect)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let screen = screen,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

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

        // Pre-compute logical line number at firstLine. The scrollback portion is
        // answered in O(1) by the screen's maintained prefix counter; only the
        // (≤ rows) grid portion is scanned, so this no longer costs O(scrollback)
        // every frame when line numbers / timestamps are shown.
        var logicalLine = 0
        if showLineNumber || showTimestamp {
            let sbPortion = min(firstLine, sbCount)
            logicalLine = screen.logicalLineCount(beforeScrollbackIndex: sbPortion)
            if firstLine > sbCount {
                for i in sbCount..<firstLine {
                    if !isWrapped(i) { logicalLine += 1 }
                }
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
                    && !hasMarkedText()
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

                let style = Self.styleIndex(bold: cell.bold, italic: cell.italic)
                if cell.underline || cell.strikethrough {
                    // Decorations are rare and need the text engine to position
                    // the rule, so they keep the old per-cell path.
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: styledFont(style: style),
                        .foregroundColor: fg,
                    ]
                    if cell.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if cell.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    (String(ch) as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                } else {
                    let baselineY = y + baseline(forStyle: style)
                    let g = glyph(for: ch, style: style)
                    if g != 0 {
                        appendGlyph(g, x: x, font: styledFont(style: style), color: fg,
                                    baselineY: baselineY, in: ctx)
                    } else {
                        runFallbacks.append((line: fallbackLine(for: ch, style: style),
                                             x: x, baselineY: baselineY, color: fg))
                    }
                }

                col += cell.wide ? 2 : 1
            }

            flushRowText(in: ctx)

            // Check if this is the last physical line of a logical line group
            let isLastOfGroup = (lineIdx + 1 >= totalLines) || !isWrapped(lineIdx + 1)

            let hasContent = cells.prefix(min(cells.count, screen.cols)).contains { c in
                !c.widePadding && c.char != " "
            }

            // Draw line number on the left side (last line of group, non-empty only)
            if showLineNumber && isLastOfGroup && hasContent {
                let ln = gutterText("\(logicalLine)")
                let lnX = Self.basePaddingLeft + lineNumberWidth - ln.width - 4
                let lnY = y + (cellHeight - gutterFont.pointSize) / 2 - 1
                drawLine(ln.line, x: lnX,
                         baselineY: lnY + gutterBaseline,
                         color: ThemeManager.shared.statusBarText, in: ctx)
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
                let tsX = bounds.width - timestampWidth
                let tsY = y + (cellHeight - gutterFont.pointSize) / 2 - 1
                drawLine(gutterText(timestampFormatter.string(from: ts)).line, x: tsX,
                         baselineY: tsY + gutterBaseline,
                         color: ThemeManager.shared.statusBarText, in: ctx)
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

        // Calculate width: each character may be wide (2 cells)
        var charWidths: CGFloat = 0
        for ch in text {
            let isWide = ch.unicodeScalars.first.map { TerminalScreen.isWideChar($0.value) } ?? false
            charWidths += isWide ? cellWidth * 2 : cellWidth
        }

        // Fill background behind the marked text (clear cursor area first)
        let tm = ThemeManager.shared
        let bgRect = NSRect(x: x, y: y, width: charWidths, height: cellHeight)
        tm.markedTextBG.setFill()
        bgRect.fill()

        // Draw underline at the bottom of the cell
        let underlineRect = NSRect(x: x, y: y + cellHeight - 1, width: charWidths, height: 1)
        tm.markedTextFG.setFill()
        underlineRect.fill()

        // Draw the text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: defaultFont,
            .foregroundColor: tm.markedTextFG,
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
            if c1 >= c0 {
                for c in c0...c1 {
                    if cells[c].widePadding { continue }
                    lineText.append(cells[c].char)
                }
            }

            // In line-selection mode, if the next selected line is a soft-wrap
            // continuation of this one, join them without a newline and keep
            // any trailing spaces (they may be real content split by the wrap).
            let nextIsWrapContinuation = selectionMode == .line
                && line < b.row
                && screen.isContinuationLine(line + 1)

            if !nextIsWrapContinuation {
                while lineText.hasSuffix(" ") { lineText.removeLast() }
            }
            text += lineText
            if line < b.row && !nextIsWrapContinuation { text += "\n" }
        }

        // Copy without surrounding whitespace: a drag selection often starts
        // before the text and ends past it, capturing leading/trailing spaces and
        // blank lines. Interior indentation (between the first and last content)
        // is preserved.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

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
        case 36, 76:
            // If IME is composing, commit the composition first
            if hasMarkedText() {
                inputContext?.discardMarkedText()
                if let marked = markedString {
                    markedString = nil
                    screen?.inputBuffer += marked
                    terminal?.write(marked)
                }
            }
            let cmd = screen?.inputBuffer.trimmingCharacters(in: .whitespaces) ?? ""
            if !cmd.isEmpty, let screen = screen {
                // Only show in tab if the input was echoed on screen
                // (prevents hidden input like passwords from appearing)
                let row = screen.grid[screen.cursorRow]
                var lineText = ""
                for c in 0..<min(screen.cursorCol, row.count) {
                    lineText.append(row[c].char)
                }
                if lineText.contains(cmd) {
                    screen.onCommandEntered?(cmd)
                    InputHistoryManager.shared.add(cmd)
                }
            }
            screen?.inputBuffer = ""
            terminal?.write("\r")
        case 51:
            // If IME is composing (e.g. Korean), let IME handle backspace first
            if hasMarkedText() {
                isBackspacingComposition = true
                inputContext?.handleEvent(event)
                isBackspacingComposition = false
                return
            }
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
                performPaste()
                return true
            case "f":
                if let sv = superview as? NSClipView, let container = sv.superview?.superview as? TerminalContainerView {
                    container.toggleFindBar(show: !container.isFindBarVisible)
                }
                return true
            case "b":
                let current = UserDefaults.standard.bool(forKey: "blockSelectionMode")
                UserDefaults.standard.set(!current, forKey: "blockSelectionMode")
                return true
            case "k":
                screen?.clearScrollback()
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

    // MARK: - Paste

    /// Pastes the clipboard into the terminal.
    ///
    /// Text is written as-is. Non-text clipboards are turned into *paths*: file
    /// URLs paste their path, and a raw image (screenshot, copied image from a
    /// browser) is written to a PNG under the cache directory and its path is
    /// pasted instead. CLI tools that accept image files — Claude Code among
    /// them — can then read the image straight from the pasted path.
    func performPaste() {
        let pb = NSPasteboard.general

        if let s = pb.string(forType: .string)?.precomposedStringWithCanonicalMapping {
            writePaste(s)
            return
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            writePaste(urls.map { quotedPath($0.path) }.joined(separator: " ") + " ")
            return
        }

        if let path = Self.savePasteboardImage(from: pb) {
            writePaste(quotedPath(path) + " ")
        }
    }

    private func writePaste(_ text: String) {
        if screen?.bracketedPasteMode == true {
            terminal?.write("\u{1b}[200~")
            terminal?.write(text)
            terminal?.write("\u{1b}[201~")
        } else {
            terminal?.write(text)
        }
    }

    private func quotedPath(_ path: String) -> String {
        let p = path.precomposedStringWithCanonicalMapping
        return p.contains(" ") ? "\"\(p)\"" : p
    }

    /// True when the clipboard holds something this view knows how to paste.
    static func pasteboardHasContent(_ pb: NSPasteboard = .general) -> Bool {
        if pb.string(forType: .string) != nil { return true }
        return pb.canReadObject(forClasses: [NSURL.self, NSImage.self],
                                options: [.urlReadingFileURLsOnly: true])
    }

    /// Writes the clipboard image to a PNG and returns its path, or nil when the
    /// clipboard holds no image.
    private static func savePasteboardImage(from pb: NSPasteboard) -> String? {
        guard let image = NSImage(pasteboard: pb) else { return nil }

        // Re-render through a bitmap rep so vector/PDF clipboards (e.g. copied
        // from Preview or Keynote) also come out as a plain PNG.
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let dir = pastedImagesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = pastedImageDateFormatter.string(from: Date())
        let url = dir.appendingPathComponent("pasted-\(stamp).png")
        do {
            try png.write(to: url)
        } catch {
            NSSound.beep()
            return nil
        }
        return url.path
    }

    /// Scratch directory holding the PNGs written by image pastes.
    static var pastedImagesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTerminal/PastedImages", isDirectory: true)
    }

    /// Drops the whole pasted-image directory. A pasted path only means anything
    /// to the commands typed while the app is running, so this runs both at quit
    /// and at launch — the launch call clears what a crash left behind.
    static func removeAllPastedImages() {
        try? FileManager.default.removeItem(at: pastedImagesDirectory)
    }

    private static let pastedImageDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    // MARK: - Edit Menu Actions

    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    @objc func paste(_ sender: Any?) {
        performPaste()
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
            return Self.pasteboardHasContent()
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

        let cell = pointToCell(convert(event.locationInWindow, from: nil))
        // Only treat clickCount==2 as a word double-click when the second click is
        // on (essentially) the same cell as the first. Otherwise two quick clicks
        // meant to reposition would select a word purely because of timing.
        let sameSpotAsLastClick = lastClickCell.map {
            $0.row == cell.row && abs($0.col - cell.col) <= 1
        } ?? false
        lastClickCell = cell

        if event.clickCount == 2 && sameSpotAsLastClick {
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
        selStart = cell
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
        // Clamp to the row's actual length: scrollback rows are trimmed of their
        // trailing blank cells, so they can be shorter than screen.cols.
        let cols = min(screen.cols, cells.count)
        guard cell.col >= 0, cell.col < cols else { return nil }

        // Word selection matching macOS Terminal / iTerm: a double-click selects a
        // contiguous run of "word" characters — letters and digits (incl. CJK and
        // other Unicode), plus the path/identifier punctuation `_-./+~\` so that
        // filenames, paths, flags, and dotted names select as a single unit. The
        // second half of a wide character (widePadding) is part of its word.
        let wordPunct: Set<Character> = ["_", "-", ".", "/", "+", "~", "\\"]
        let isWord: (Int) -> Bool = { i in
            let c = cells[i]
            if c.widePadding { return true }
            return c.char.isLetter || c.char.isNumber || wordPunct.contains(c.char)
        }

        // Clicking on whitespace / punctuation outside a word selects nothing.
        guard isWord(cell.col) else { return nil }

        var start = cell.col
        while start > 0 && isWord(start - 1) { start -= 1 }
        var end = cell.col
        while end < cols - 1 && isWord(end + 1) { end += 1 }

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
            performPaste()
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

        // When backspacing the last jamo, IME may commit it instead of deleting;
        // suppress the commit so a single backspace clears the last consonant.
        if isBackspacingComposition {
            markedString = nil
            needsDisplay = true
            return
        }

        markedString = nil
        if let screen = screen {
            screen.inputBuffer += str
            // inputBuffer is reset on Enter, but TUI apps (vim, less, etc.) may
            // never let an Enter through to the shell-prompt path — cap it to
            // prevent unbounded String growth across long sessions.
            if screen.inputBuffer.count > 4096 {
                screen.inputBuffer = String(screen.inputBuffer.suffix(4096))
            }
        }
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
        // Position the IME candidate window just below the cursor cell
        let rectInView = NSRect(x: x, y: y + cellHeight, width: cellWidth, height: 0)
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
