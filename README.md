# Claude Chat Manager

PowerShell/WPF application for managing Claude.ai conversations.

## Features

- WebView2 authentication (secure browser-based login)
- Paginated fetch (handles large conversation histories)
- Search modes: title, content, regex, UUID
- Content indexing for deep search
- Date filtering
- Bulk operations (select, export, delete)
- Caching (metadata and index persistence)
- Dark theme UI

## Quick Start

```powershell
.\ClaudeChatManager.ps1
```

## Architecture (STREAM)

```
ClaudeChatManager/
├── ClaudeChatManager.ps1    # Entry point (~100 lines)
├── S_Structures/            # What things ARE
├── T_Tasks/                 # What you DO  
├── R_Records/               # What's happening NOW
├── E_Events/                # What happens WHEN
├── A_Adapters/              # Interface to outside
├── M_Markup/                # Presentation (XAML)
├── _Auxiliaries/            # Shared utilities
└── _AppData/                # Config + runtime data
```

## Configuration

Edit `_AppData/config.json`:

```json
{
  "Api": {
    "FetchTimeoutSeconds": 180,
    "MaxPaginationPages": 100,
    "RequestDelayMs": 100
  },
  "UI": {
    "SearchDebounceMs": 300,
    "SidebarWidth": 180,
    "RememberWindowState": true
  },
  "Cache": {
    "Enabled": true,
    "MaxCacheAgeDays": 7,
    "MaxIndexedChats": 500
  }
}
```

## Data Storage

All data in `_AppData/`:

```
_AppData/
├── Defaults.ps1      # Factory defaults (code)
├── ConfigManager.ps1 # Config loader (code)
├── config.json       # Your settings
├── cache/            # Metadata + index cache
├── webview2/         # WebView2 SDK + browser data
├── credentials       # Encrypted session (AES)
└── windowstate       # Window position/size
```

Credentials are encrypted with machine-specific AES keys (can only be decrypted on the same machine by the same user).

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Enter` | Open selected chat in browser |
| `Double-click` | Open chat in browser |
| `Space` | Toggle row selection |
| `Ctrl+O` | Open selected in browser |
| `Ctrl+F` | Focus search |
| `Ctrl+B` | Toggle sidebar |
| `Ctrl+A` | Select all visible |
| `Shift+Click` | Range select |
| `Up/Down` | Navigate rows |
| `Escape` | Clear search |

## Search Syntax

| Pattern | Description | Example |
|---------|-------------|---------|
| Plain text | Contains search | `hello world` |
| `/pattern/` | Regex match | `/\btest\b/` |
| `word1\|word2` | OR search (any match) | `python\|javascript` |
| `id:value` | Find by ID | `id:abc-123-def` |
| `ids:a,b,c` | Find multiple IDs | `ids:abc,def,ghi` |
| `not:word` | Exclude matches | `python not:django` |
| `not:a,b,c` | Exclude multiple | `code not:test,debug` |

## Uninstall

```powershell
.\Uninstall.ps1                    # Remove runtime data
.\Uninstall.ps1 -Force             # No prompts
.\Uninstall.ps1 -IncludeConfig     # Also remove config.json
```

Then delete the application folder.

## Requirements

- PowerShell 7.0+
- Windows 10/11
- WebView2 Runtime (auto-downloaded if missing)
