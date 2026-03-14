import AppKit

class InputHistoryPanel: NSPanel {
    static var shared: InputHistoryPanel?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private var filteredHistory: [String] = []
    private var onSelect: ((String) -> Void)?

    static func show(onSelect: @escaping (String) -> Void) {
        if let existing = shared {
            existing.onSelect = onSelect
            existing.reload()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let panel = InputHistoryPanel(onSelect: onSelect)
        shared = panel
        panel.makeKeyAndOrderFront(nil)
    }

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "입력 히스토리"
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        center()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView = container

        // Search field
        searchField.placeholderString = "검색..."
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        container.addSubview(searchField)

        // Table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.title = "명령어"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.target = self
        tableView.rowHeight = 22
        tableView.style = .plain

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Clear button
        let clearButton = NSButton(title: "전체 삭제", target: self, action: #selector(clearHistory))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .rounded
        container.addSubview(clearButton)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -8),

            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            clearButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        reload()
    }

    func reload() {
        let query = searchField.stringValue.lowercased()
        let all = InputHistoryManager.shared.history
        filteredHistory = query.isEmpty ? all : all.filter { $0.lowercased().contains(query) }
        tableView.reloadData()
    }

    @objc private func searchChanged() {
        reload()
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredHistory.count else { return }
        onSelect?(filteredHistory[row])
    }

    @objc private func clearHistory() {
        InputHistoryManager.shared.clear()
        reload()
    }
}

extension InputHistoryPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredHistory.count
    }
}

extension InputHistoryPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("CommandCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
            ?? {
                let tf = NSTextField(labelWithString: "")
                tf.identifier = id
                tf.lineBreakMode = .byTruncatingTail
                tf.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                return tf
            }()
        cell.stringValue = filteredHistory[row]
        return cell
    }
}
