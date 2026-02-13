import AppKit

class TerminalScreen {
    struct Cell {
        var char: Character = " "
        var fg: NSColor = defaultFG
        var bg: NSColor = .clear
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var strikethrough = false
        var invisible = false
        var wide = false        // First cell of a wide character
        var widePadding = false // Second cell (placeholder) of a wide character
    }

    var rows: Int
    var cols: Int
    var grid: [[Cell]]
    var scrollback: [[Cell]] = []
    static let maxScrollback = 5000

    var cursorRow = 0
    var cursorCol = 0
    var savedCursorRow = 0
    var savedCursorCol = 0

    var scrollTop = 0
    var scrollBottom: Int

    // Current text style
    var currentFG: NSColor = defaultFG
    var currentBG: NSColor = .clear
    var currentBold = false
    var currentDim = false
    var currentItalic = false
    var currentUnderline = false
    var currentStrikethrough = false
    var currentInvisible = false

    // Modes
    var applicationCursorKeys = false
    var showCursor = true
    var autoWrap = true
    var bracketedPasteMode = false
    var insertMode = false

    // Alternate screen buffer
    private var savedMainGrid: [[Cell]]?
    private var savedMainScrollback: [[Cell]]?
    private var savedMainCursorRow = 0
    private var savedMainCursorCol = 0

    // Parser
    enum ParserState { case normal, escape, csi, osc, charset, stringSequence }
    var parserState: ParserState = .normal
    var csiParams = ""
    var csiIntermediate = ""
    var oscString = ""
    private var lastPrintedChar: UnicodeScalar = " "

    var onChange: (() -> Void)?
    var onBell: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onCommandEntered: ((String) -> Void)?
    var onResponse: ((String) -> Void)?
    var currentDirectory: String?
    var inputBuffer = ""
    var recordingHandle: FileHandle?
    private var recordingLineBuffer = ""
    private var recordingPendingCR = false

    private func recordText(_ text: String) {
        if recordingPendingCR {
            recordingLineBuffer = ""
            recordingPendingCR = false
        }
        recordingLineBuffer += text
    }

    private func recordFlushLine() {
        guard let handle = recordingHandle else { return }
        recordingPendingCR = false
        let line = recordingLineBuffer.replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression
        )
        recordingLineBuffer = ""
        guard !line.isEmpty else { return }
        if let data = (line + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }

    // MARK: - Colors

    static let defaultFG = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)

    static let ansiColors: [NSColor] = [
        NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1),
        NSColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1),
        NSColor(red: 0.8, green: 0.8, blue: 0.2, alpha: 1),
        NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1),
        NSColor(red: 0.8, green: 0.3, blue: 0.8, alpha: 1),
        NSColor(red: 0.3, green: 0.8, blue: 0.8, alpha: 1),
        NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1),
    ]

    static let brightColors: [NSColor] = [
        NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1),
        NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1),
        NSColor(red: 0.3, green: 1.0, blue: 0.3, alpha: 1),
        NSColor(red: 1.0, green: 1.0, blue: 0.3, alpha: 1),
        NSColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1),
        NSColor(red: 1.0, green: 0.4, blue: 1.0, alpha: 1),
        NSColor(red: 0.4, green: 1.0, blue: 1.0, alpha: 1),
        NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),
    ]

    // MARK: - Init

    init(rows: Int = 25, cols: Int = 80) {
        self.rows = rows
        self.cols = cols
        self.scrollBottom = rows - 1
        self.grid = Self.emptyGrid(rows: rows, cols: cols)
    }

    static func emptyGrid(rows: Int, cols: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
    }

    // MARK: - Process Data

    func process(_ data: Data) {
        guard let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return }
        // NFC 정규화: macOS 파일시스템의 NFD 한글(ㄱ+ㅏ)을 조합형(가)으로 변환
        let normalized = str.precomposedStringWithCanonicalMapping
        for scalar in normalized.unicodeScalars {
            processScalar(scalar)
        }
        onChange?()
    }

    func processScalar(_ scalar: UnicodeScalar) {
        switch parserState {
        case .normal:          processNormal(scalar)
        case .escape:          processEscape(scalar)
        case .csi:             processCSI(scalar)
        case .osc:             processOSC(scalar)
        case .charset:         parserState = .normal
        case .stringSequence:  processStringSequence(scalar)
        }
    }

    private func processNormal(_ s: UnicodeScalar) {
        switch s.value {
        case 0x07: onBell?()
        case 0x08: if cursorCol > 0 { cursorCol -= 1 }
        case 0x09: cursorCol = min((cursorCol / 8 + 1) * 8, cols - 1)
        case 0x0A, 0x0B, 0x0C:
            recordFlushLine()
            lineFeed()
        case 0x0D:
            recordingPendingCR = true
            cursorCol = 0
        case 0x1B: parserState = .escape
        case 0x00...0x1F: break
        default:
            recordText(String(s))
            putChar(s)
        }
    }

    private func processEscape(_ s: UnicodeScalar) {
        switch s {
        case "[":  parserState = .csi; csiParams = ""; csiIntermediate = ""
        case "]":  parserState = .osc; oscString = ""
        case "(", ")", "*", "+": parserState = .charset
        case "7":  savedCursorRow = cursorRow; savedCursorCol = cursorCol; parserState = .normal
        case "8":  cursorRow = savedCursorRow; cursorCol = savedCursorCol; parserState = .normal
        case "D":  lineFeed(); parserState = .normal
        case "M":  reverseLineFeed(); parserState = .normal
        case "c":  reset(); parserState = .normal
        case "P", "_", "^", "X":
            // DCS, APC, PM, SOS — consume until ST
            parserState = .stringSequence
        case "\\":
            // ST (String Terminator) — just return to normal
            parserState = .normal
        default:   parserState = .normal
        }
    }

    private func processCSI(_ s: UnicodeScalar) {
        let v = s.value
        if v >= 0x30 && v <= 0x3F {
            // Parameter bytes: 0-9 ; < = > ?
            csiParams.append(Character(s))
        } else if v >= 0x20 && v <= 0x2F {
            // Intermediate bytes: space ! " # $ % & ' ( ) * + , - . /
            csiIntermediate.append(Character(s))
        } else if v >= 0x40 && v <= 0x7E {
            // Final byte
            handleCSI(params: csiParams, intermediate: csiIntermediate, cmd: Character(s))
            parserState = .normal
        } else {
            parserState = .normal
        }
    }

    private func processOSC(_ s: UnicodeScalar) {
        if s.value == 0x07 {
            handleOSC(oscString); parserState = .normal
        } else if s.value == 0x1B {
            handleOSC(oscString); parserState = .escape
        } else {
            oscString.append(Character(s))
        }
    }

    private func processStringSequence(_ s: UnicodeScalar) {
        if s.value == 0x1B {
            // ESC might start ST (\e\\) or another sequence
            parserState = .escape
        } else if s.value == 0x07 {
            // BEL also terminates string sequences
            parserState = .normal
        }
        // else: consume and discard
    }

    // MARK: - Character Output

    private func putChar(_ s: UnicodeScalar) {
        let w = Self.isWideChar(s.value)

        // Wide char needs 2 cells — if at last column, wrap first
        if w && cursorCol == cols - 1 {
            // Fill current cell with space and wrap
            grid[cursorRow][cursorCol] = Cell()
            if autoWrap { cursorCol = 0; lineFeed() }
            else { return }
        }

        if cursorCol >= cols {
            if autoWrap { cursorCol = 0; lineFeed() }
            else { cursorCol = cols - 1 }
        }
        guard cursorRow >= 0, cursorRow < rows, cursorCol >= 0, cursorCol < cols else { return }

        // If overwriting a wide char's padding cell, clear the first cell too
        if grid[cursorRow][cursorCol].widePadding && cursorCol > 0 {
            grid[cursorRow][cursorCol - 1] = Cell()
        }
        // If overwriting a wide char's first cell, clear the padding cell too
        if grid[cursorRow][cursorCol].wide && cursorCol + 1 < cols {
            grid[cursorRow][cursorCol + 1] = Cell()
        }

        if insertMode {
            let insertCount = w ? 2 : 1
            grid[cursorRow].insert(contentsOf: Array(repeating: Cell(), count: insertCount), at: cursorCol)
            grid[cursorRow] = Array(grid[cursorRow].prefix(cols))
        }

        grid[cursorRow][cursorCol] = Cell(
            char: Character(s), fg: currentFG, bg: currentBG,
            bold: currentBold, dim: currentDim, italic: currentItalic,
            underline: currentUnderline, strikethrough: currentStrikethrough,
            invisible: currentInvisible, wide: w
        )
        lastPrintedChar = s
        cursorCol += 1

        if w && cursorCol < cols {
            // Place padding cell for second half of wide character
            grid[cursorRow][cursorCol] = Cell(
                fg: currentFG, bg: currentBG, widePadding: true
            )
            cursorCol += 1
        }
    }

    // MARK: - Wide Character Detection

    static func isWideChar(_ v: UInt32) -> Bool {
        if v >= 0x1100 && v <= 0x115F { return true }   // Hangul Jamo
        if v >= 0x2329 && v <= 0x232A { return true }   // Angle brackets
        if v >= 0x2E80 && v <= 0x303E { return true }   // CJK Radicals
        if v >= 0x3041 && v <= 0x33BF { return true }   // Hiragana, Katakana, CJK symbols
        if v >= 0x3400 && v <= 0x4DBF { return true }   // CJK Extension A
        if v >= 0x4E00 && v <= 0x9FFF { return true }   // CJK Unified Ideographs
        if v >= 0xA000 && v <= 0xA4CF { return true }   // Yi
        if v >= 0xA960 && v <= 0xA97C { return true }   // Hangul Jamo Extended-A
        if v >= 0xAC00 && v <= 0xD7A3 { return true }   // Hangul Syllables
        if v >= 0xF900 && v <= 0xFAFF { return true }   // CJK Compatibility Ideographs
        if v >= 0xFE10 && v <= 0xFE19 { return true }   // Vertical forms
        if v >= 0xFE30 && v <= 0xFE6F { return true }   // CJK Compatibility Forms
        if v >= 0xFF01 && v <= 0xFF60 { return true }   // Fullwidth Forms
        if v >= 0xFFE0 && v <= 0xFFE6 { return true }   // Fullwidth Signs
        if v >= 0x1B000 && v <= 0x1B2FF { return true }  // Kana Supplement
        if v >= 0x1F300 && v <= 0x1F9FF { return true }  // Emoji Symbols
        if v >= 0x1FA00 && v <= 0x1FAFF { return true }  // Emoji Extended
        if v >= 0x20000 && v <= 0x2FFFF { return true }  // CJK Extension B+
        if v >= 0x30000 && v <= 0x3FFFF { return true }  // CJK Extension G+
        return false
    }

    // MARK: - Scrolling

    func lineFeed() {
        if cursorRow == scrollBottom {
            scrollUp()
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    func reverseLineFeed() {
        if cursorRow == scrollTop { scrollDown() }
        else if cursorRow > 0 { cursorRow -= 1 }
    }

    private func scrollUp() {
        if savedMainGrid == nil {
            scrollback.append(grid[scrollTop])
            if scrollback.count > Self.maxScrollback {
                scrollback.removeFirst(scrollback.count - Self.maxScrollback)
            }
        }
        for r in scrollTop..<scrollBottom { grid[r] = grid[r + 1] }
        grid[scrollBottom] = Array(repeating: Cell(), count: cols)
    }

    private func scrollDown() {
        for r in stride(from: scrollBottom, to: scrollTop, by: -1) { grid[r] = grid[r - 1] }
        grid[scrollTop] = Array(repeating: Cell(), count: cols)
    }

    private func scrollUpN(_ n: Int) {
        for _ in 0..<n { scrollUp() }
    }

    private func scrollDownN(_ n: Int) {
        for _ in 0..<n { scrollDown() }
    }

    // MARK: - CSI Handler

    private func handleCSI(params: String, intermediate: String, cmd: Character) {
        // Private mode: ?
        if params.hasPrefix("?") {
            handlePrivateMode(params: String(params.dropFirst()), cmd: cmd)
            return
        }

        // Secondary DA: >
        if params.hasPrefix(">") {
            if cmd == "c" {
                onResponse?("\u{1b}[>0;0;0c")
            }
            return
        }

        // Tertiary DA: =
        if params.hasPrefix("=") {
            return
        }

        // Cursor shape: CSI Ps SP q
        if intermediate == " " && cmd == "q" {
            // Silently accept cursor shape changes
            return
        }

        // DECSTR soft reset: CSI ! p
        if intermediate == "!" && cmd == "p" {
            reset()
            return
        }

        let parts = params.split(separator: ";").map { Int($0) ?? 0 }
        let p1 = parts.first ?? 0

        switch cmd {
        case "A": cursorRow = max(cursorRow - max(p1, 1), 0)
        case "B": cursorRow = min(cursorRow + max(p1, 1), rows - 1)
        case "C": cursorCol = min(cursorCol + max(p1, 1), cols - 1)
        case "D": cursorCol = max(cursorCol - max(p1, 1), 0)
        case "E": cursorCol = 0; cursorRow = min(cursorRow + max(p1, 1), rows - 1)
        case "F": cursorCol = 0; cursorRow = max(cursorRow - max(p1, 1), 0)
        case "G": cursorCol = min(max(p1, 1) - 1, cols - 1)
        case "H", "f":
            let r = (parts.count > 0 && parts[0] > 0) ? parts[0] : 1
            let c = (parts.count > 1 && parts[1] > 0) ? parts[1] : 1
            cursorRow = min(max(r - 1, 0), rows - 1)
            cursorCol = min(max(c - 1, 0), cols - 1)
        case "J": eraseInDisplay(p1)
        case "K": eraseInLine(p1)
        case "L": insertLines(max(p1, 1))
        case "M": deleteLines(max(p1, 1))
        case "P": deleteChars(max(p1, 1))
        case "@": insertChars(max(p1, 1))
        case "X": eraseChars(max(p1, 1))
        case "S": scrollUpN(max(p1, 1))
        case "T": scrollDownN(max(p1, 1))
        case "b":
            // Repeat last printed character
            let count = max(p1, 1)
            for _ in 0..<count { putChar(lastPrintedChar) }
        case "c":
            // Primary Device Attributes
            if params.isEmpty || params == "0" {
                onResponse?("\u{1b}[?1;2c")
            }
        case "d": cursorRow = min(max(p1, 1) - 1, rows - 1)
        case "h":
            // Set mode (non-private)
            for mode in parts {
                switch mode {
                case 4: insertMode = true
                default: break
                }
            }
        case "l":
            // Reset mode (non-private)
            for mode in parts {
                switch mode {
                case 4: insertMode = false
                default: break
                }
            }
        case "m": handleSGR(parts)
        case "n":
            // Device Status Report
            if p1 == 6 {
                // Cursor Position Report
                onResponse?("\u{1b}[\(cursorRow + 1);\(cursorCol + 1)R")
            } else if p1 == 5 {
                // Status Report: OK
                onResponse?("\u{1b}[0n")
            }
        case "r":
            scrollTop = max((parts.count > 0 && parts[0] > 0 ? parts[0] - 1 : 0), 0)
            scrollBottom = min((parts.count > 1 && parts[1] > 0 ? parts[1] - 1 : rows - 1), rows - 1)
            cursorRow = scrollTop; cursorCol = 0
        case "s": savedCursorRow = cursorRow; savedCursorCol = cursorCol
        case "t":
            // Window manipulation — silently ignore
            break
        case "u": cursorRow = min(savedCursorRow, rows-1); cursorCol = min(savedCursorCol, cols-1)
        default: break
        }
    }

    // MARK: - Private Mode

    private func handlePrivateMode(params: String, cmd: Character) {
        let modes = params.split(separator: ";").compactMap { Int($0) }
        let enable = cmd == "h"
        for mode in modes {
            switch mode {
            case 1:    applicationCursorKeys = enable
            case 7:    autoWrap = enable
            case 12:   break // Cursor blink — accept silently
            case 25:   showCursor = enable
            case 47, 1047:
                if enable { enterAltScreen() } else { exitAltScreen() }
            case 1000, 1002, 1003:
                break // Mouse tracking modes — accept silently
            case 1004:
                break // Focus events — accept silently
            case 1006:
                break // SGR mouse mode — accept silently
            case 1049:
                if enable {
                    savedCursorRow = cursorRow; savedCursorCol = cursorCol
                    enterAltScreen()
                } else {
                    exitAltScreen()
                    cursorRow = savedCursorRow; cursorCol = savedCursorCol
                }
            case 2004:
                bracketedPasteMode = enable
            case 2026:
                break // Synchronized output — accept silently
            default: break
            }
        }
    }

    private func enterAltScreen() {
        guard savedMainGrid == nil else { return }
        savedMainGrid = grid
        savedMainScrollback = scrollback
        savedMainCursorRow = cursorRow
        savedMainCursorCol = cursorCol
        grid = Self.emptyGrid(rows: rows, cols: cols)
        scrollback = []
        cursorRow = 0; cursorCol = 0
        scrollTop = 0; scrollBottom = rows - 1
    }

    private func exitAltScreen() {
        guard let saved = savedMainGrid else { return }
        grid = saved
        scrollback = savedMainScrollback ?? []
        cursorRow = savedMainCursorRow
        cursorCol = savedMainCursorCol
        savedMainGrid = nil; savedMainScrollback = nil
        scrollTop = 0; scrollBottom = rows - 1
    }

    // MARK: - Erase Operations

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            for c in cursorCol..<cols { grid[cursorRow][c] = Cell() }
            for r in (cursorRow+1)..<rows { grid[r] = Array(repeating: Cell(), count: cols) }
        case 1:
            for c in 0...min(cursorCol, cols-1) { grid[cursorRow][c] = Cell() }
            for r in 0..<cursorRow { grid[r] = Array(repeating: Cell(), count: cols) }
        case 2:
            for r in 0..<rows { grid[r] = Array(repeating: Cell(), count: cols) }
        case 3:
            // Erase display + clear scrollback
            for r in 0..<rows { grid[r] = Array(repeating: Cell(), count: cols) }
            scrollback.removeAll()
        default: break
        }
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 0: for c in cursorCol..<cols { grid[cursorRow][c] = Cell() }
        case 1: for c in 0...min(cursorCol, cols-1) { grid[cursorRow][c] = Cell() }
        case 2: grid[cursorRow] = Array(repeating: Cell(), count: cols)
        default: break
        }
    }

    private func insertLines(_ n: Int) {
        for _ in 0..<min(n, scrollBottom - cursorRow + 1) {
            grid.remove(at: min(scrollBottom, grid.count - 1))
            grid.insert(Array(repeating: Cell(), count: cols), at: cursorRow)
        }
    }

    private func deleteLines(_ n: Int) {
        for _ in 0..<min(n, scrollBottom - cursorRow + 1) {
            grid.remove(at: cursorRow)
            grid.insert(Array(repeating: Cell(), count: cols), at: min(scrollBottom, grid.count - 1))
        }
    }

    private func deleteChars(_ n: Int) {
        let count = min(n, cols - cursorCol)
        grid[cursorRow].removeSubrange(cursorCol..<(cursorCol + count))
        grid[cursorRow].append(contentsOf: Array(repeating: Cell(), count: count))
    }

    private func insertChars(_ n: Int) {
        let count = min(n, cols - cursorCol)
        grid[cursorRow].insert(contentsOf: Array(repeating: Cell(), count: count), at: cursorCol)
        grid[cursorRow] = Array(grid[cursorRow].prefix(cols))
    }

    private func eraseChars(_ n: Int) {
        for c in cursorCol..<min(cursorCol + n, cols) { grid[cursorRow][c] = Cell() }
    }

    // MARK: - SGR (Colors / Styles)

    private func handleSGR(_ codes: [Int]) {
        let params = codes.isEmpty ? [0] : codes
        var i = 0
        while i < params.count {
            let c = params[i]
            switch c {
            case 0:
                currentFG = Self.defaultFG; currentBG = .clear
                currentBold = false; currentDim = false; currentItalic = false
                currentUnderline = false; currentStrikethrough = false; currentInvisible = false
            case 1:  currentBold = true
            case 2:  currentDim = true
            case 3:  currentItalic = true
            case 4:  currentUnderline = true
            case 7:
                let tmp = currentFG; currentFG = (currentBG == .clear ? .terminalBG : currentBG); currentBG = tmp
            case 8:  currentInvisible = true
            case 9:  currentStrikethrough = true
            case 22: currentBold = false; currentDim = false
            case 23: currentItalic = false
            case 24: currentUnderline = false
            case 27: currentFG = Self.defaultFG; currentBG = .clear
            case 28: currentInvisible = false
            case 29: currentStrikethrough = false
            case 30...37: currentFG = Self.ansiColors[c - 30]
            case 38:
                if i+2 < params.count && params[i+1] == 5 { currentFG = Self.color256(params[i+2]); i += 2 }
                else if i+4 < params.count && params[i+1] == 2 {
                    currentFG = NSColor(red: CGFloat(params[i+2])/255, green: CGFloat(params[i+3])/255, blue: CGFloat(params[i+4])/255, alpha: 1); i += 4
                }
            case 39: currentFG = Self.defaultFG
            case 40...47: currentBG = Self.ansiColors[c - 40]
            case 48:
                if i+2 < params.count && params[i+1] == 5 { currentBG = Self.color256(params[i+2]); i += 2 }
                else if i+4 < params.count && params[i+1] == 2 {
                    currentBG = NSColor(red: CGFloat(params[i+2])/255, green: CGFloat(params[i+3])/255, blue: CGFloat(params[i+4])/255, alpha: 1); i += 4
                }
            case 49: currentBG = .clear
            case 90...97:  currentFG = Self.brightColors[c - 90]
            case 100...107: currentBG = Self.brightColors[c - 100]
            default: break
            }
            i += 1
        }
    }

    // MARK: - OSC / Reset / Resize

    private func handleOSC(_ str: String) {
        if str.hasPrefix("0;") || str.hasPrefix("2;") {
            onTitleChange?(String(str.dropFirst(2)))
        } else if str.hasPrefix("7;") {
            // OSC 7: current working directory — file://hostname/path
            let urlStr = String(str.dropFirst(2))
            if let url = URL(string: urlStr), url.scheme == "file" {
                currentDirectory = url.path
            } else {
                currentDirectory = urlStr
            }
            onTitleChange?(currentDirectory ?? urlStr)
        }
    }

    func reset() {
        cursorRow = 0; cursorCol = 0
        scrollTop = 0; scrollBottom = rows - 1
        currentFG = Self.defaultFG; currentBG = .clear
        currentBold = false; currentDim = false; currentItalic = false
        currentUnderline = false; currentStrikethrough = false; currentInvisible = false
        applicationCursorKeys = false; showCursor = true; autoWrap = true
        bracketedPasteMode = false; insertMode = false
        for r in 0..<rows { grid[r] = Array(repeating: Cell(), count: cols) }
    }

    func resize(newRows: Int, newCols: Int) {
        guard newRows != rows || newCols != cols else { return }
        var newGrid = Self.emptyGrid(rows: newRows, cols: newCols)
        for r in 0..<min(rows, newRows) {
            for c in 0..<min(cols, newCols) { newGrid[r][c] = grid[r][c] }
        }
        grid = newGrid; rows = newRows; cols = newCols
        scrollTop = 0; scrollBottom = rows - 1
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    /// Extract all text content (scrollback + current screen) as a plain string.
    func extractText() -> String {
        var lines: [String] = []
        for row in scrollback {
            lines.append(cellsToString(row))
        }
        for r in 0..<rows {
            lines.append(cellsToString(grid[r]))
        }
        // Trim trailing empty lines
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func cellsToString(_ cells: [Cell]) -> String {
        var s = ""
        for cell in cells {
            if cell.widePadding { continue }
            s.append(cell.char)
        }
        // Trim trailing spaces
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    static func color256(_ code: Int) -> NSColor {
        if code < 8 { return ansiColors[code] }
        if code < 16 { return brightColors[code - 8] }
        if code < 232 {
            let a = code - 16
            return NSColor(red: CGFloat((a/36)%6)/5, green: CGFloat((a/6)%6)/5, blue: CGFloat(a%6)/5, alpha: 1)
        }
        let g = CGFloat(code - 232) / 23.0
        return NSColor(red: g, green: g, blue: g, alpha: 1)
    }
}
