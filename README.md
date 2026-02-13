# MacTerminal

A native macOS terminal emulator built with SwiftUI + AppKit.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Terminal Emulation** — Full pseudoterminal (`forkpty`) with `xterm-256color` support
- **Tabs** — Multi-tab interface with drag & drop reordering
- **SSH Bookmarks** — Tree-structured connection manager with folders and subfolders
- **Drag & Drop** — Reorder bookmarks and move them between folders
- **Find** — In-terminal search with next/previous navigation (Cmd+F)
- **Recording** — Record terminal sessions to text files
- **Save Output** — Export terminal content to file (Cmd+S)
- **Customization** — Configurable font, background color, and text color
- **Block Selection** — Toggle block selection mode for text
- **Multi-Window** — Detachable terminal windows

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

## Project Structure

```
MacTerminal/
├── MacTerminalApp.swift          # App entry point, menu commands
├── ContentView.swift             # Main layout (sidebar + terminal)
├── Models/
│   ├── SSHBookmark.swift         # SSH connection data model
│   ├── SSHBookmarkStore.swift    # Tree-based bookmark persistence
│   ├── SidebarItem.swift         # Tree node (folder / bookmark leaf)
│   ├── TerminalTab.swift         # Tab state management
│   └── WindowManager.swift       # Multi-window tracking
├── Terminal/
│   ├── PseudoTerminal.swift      # PTY process management (forkpty)
│   └── TerminalScreen.swift      # Terminal rendering engine
└── Views/
    ├── SidebarView.swift         # SSH bookmark tree with drag & drop
    ├── SSHBookmarkEditView.swift # Bookmark add/edit form
    ├── TabBarView.swift          # Tab bar with drag reordering
    ├── TerminalView.swift        # NSViewRepresentable terminal bridge
    └── DetachedWindowContent.swift
```

## License

MIT
