# MacTerminal

A native macOS terminal emulator built with SwiftUI + AppKit.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Terminal Emulation** — Full pseudoterminal (`forkpty`) with `xterm-256color` support
- **Tabs** — Multi-tab interface with drag & drop reordering (Cmd+T / Cmd+W)
- **Split View** — Side-by-side terminal panes within a tab (Cmd+D / Cmd+Shift+D to close)
- **SSH Bookmarks** — Tree-structured connection manager with folders and subfolders
- **SSH Auto-Password** — Automatically detects SSH password prompt and sends stored password (one-shot)
- **Commands** — Save frequently used commands and double-click to auto-input into terminal
- **Right-Click Copy/Paste** — Right-click to copy selection or paste if no selection
- **Background Tab Updates** — Tabs continue processing data even when not focused, with blink indicator for unread output
- **Themes** — Dark, Gray, and Light themes with sidebar support (View > Theme)
- **Line Numbers** — Toggle line numbers on the left side (View > Show Line Number)
- **Timestamps** — Per-line timestamps on the right side (View > Show Timestamp)
- **Logical Line Tracking** — Wrapped lines are treated as a single logical line for line numbers and timestamps
- **Settings Export/Import** — Export and import connections, commands, theme, and color settings (File > Settings)
- **Folder State Persistence** — Sidebar folder expanded/collapsed state remembered across restarts
- **Font Zoom** — Cmd + Mouse Wheel to resize terminal font instantly (8pt–72pt)
- **NFC Normalization** — File drag & drop and clipboard paste use NFC Unicode form (fixes Korean filenames)
- **Text Wrap Toggle** — Turn text wrapping on/off with horizontal scrolling (View > Text Wrap)
- **Smart Double-Click** — Double-click selects text between 2+ consecutive spaces (selects phrases, not just words)
- **Status Bar** — Bottom bar showing logical line number (Ln) and column (Col) with selection range
- **Drag & Drop** — Reorder bookmarks and move them between folders
- **Find** — In-terminal search with next/previous navigation (Cmd+F)
- **Recording** — Record terminal sessions to text files
- **Save Output** — Export terminal content to file (Cmd+S)
- **Customization** — Configurable font, background color, and text color
- **Block Selection** — Toggle block selection mode for text
- **Multi-Window** — Detachable terminal windows with full terminal updates in detached windows
- **Clean Shell Exit** — `exit` command properly terminates shell and all child processes without freezing
- **Process Group Cleanup** — Tab close kills entire process group (shell + SSH + child processes)
- **Working Directory** — Starts in home directory; new tabs inherit current directory
- **Auto Update** — Checks for new releases via GitHub Releases API

## Screenshots

![MacTerminal](screenshots/main.png)

## Install

Download `MacTerminal.dmg` from [Releases](https://github.com/secondlook-hub/MacTerminal/releases), or grab it directly from the repository.

## Build from Source

```bash
git clone https://github.com/secondlook-hub/MacTerminal.git
cd MacTerminal
xcodebuild -scheme MacTerminal -configuration Release build
```

Requires **Xcode 15+** and **macOS 13.0 Ventura** or later.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+T | New Tab |
| Cmd+W | Close Tab |
| Cmd+D | Split View |
| Cmd+Shift+D | Close Split View |
| Cmd+F | Find |
| Cmd+S | Save Shell Content |
| Cmd+K | Clear Scrollback |
| Cmd+C | Copy (with selection) |
| Cmd+V | Paste |
| Cmd+Scroll | Font Zoom In/Out |
| Right-Click | Copy selection / Paste (no selection) |

## Project Structure

```
MacTerminal/
├── MacTerminalApp.swift          # App entry point, menu commands
├── ContentView.swift             # Main layout (sidebar + terminal)
├── Models/
│   ├── SplitNode.swift           # Split view tree model (pane / split node)
│   ├── SSHBookmark.swift         # SSH connection data model
│   ├── SSHBookmarkStore.swift    # Tree-based bookmark persistence
│   ├── SidebarItem.swift         # Tree node (folder / bookmark leaf)
│   ├── CommandItem.swift         # Saved commands model & persistence
│   ├── ThemeManager.swift        # Theme management (Dark/Gray/Light)
│   ├── SettingsExporter.swift    # Settings export/import
│   ├── TerminalTab.swift         # Tab & split pane state management
│   ├── UpdateChecker.swift       # GitHub Releases update checker
│   └── WindowManager.swift       # Multi-window tracking
├── Terminal/
│   ├── PseudoTerminal.swift      # PTY process management (forkpty)
│   └── TerminalScreen.swift      # Terminal rendering engine
└── Views/
    ├── SplitTerminalView.swift   # Recursive split view renderer
    ├── SidebarView.swift         # Tabbed sidebar (Connections + Commands)
    ├── SSHBookmarkEditView.swift # Bookmark add/edit form
    ├── CommandEditView.swift     # Command add/edit form
    ├── TabBarView.swift          # Tab bar with drag reordering
    ├── TerminalView.swift        # NSViewRepresentable terminal bridge
    └── DetachedWindowContent.swift
```

## License

MIT
