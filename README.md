## Search Syntax

| Syntax | Example | Description |
|--------|---------|-------------|
| `text` | `hello` | Substring match (default) |
| `foo\|bar\|baz` | `python\|javascript\|rust` | OR search - matches any term |
| `/pattern/` | `/\d{4}-\d{2}/` | Regular expression |
| `id:value` | `id:abc123` | Search by single ID (partial match) |
| `ids:a,b,c` | `ids:abc,def,ghi` | Search multiple IDs (comma-separated) |
| `text not:word` | `python not:beginner` | Exclude terms from results |
| `not:a,b,c` | `not:test,debug` | Exclusion only (match all except) |

## Examples

Find chats about Python OR JavaScript:
```
python|javascript
```

Find chats with dates like 2024-01:
```
/\d{4}-\d{2}/
```

Find project chats but exclude test conversations:
```
project|work not:test,debug,scratch
```

Find specific chat by ID:
```
id:550e8400-e29b
```

Delete specific chats by ID:
```
ids:abc123,def456,ghi789
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+F` | Focus search box |
| `Ctrl+A` | Select all visible |
| `Ctrl+B` | Toggle sidebar |
| `Ctrl+Z` | Restore last deleted (local only) |
| `Escape` | Clear search / Deselect all |
| `Delete` | Delete selected |
| `Space` | Toggle selection on current row |
| `↑` / `↓` | Navigate rows |
| `Shift+↑/↓` | Navigate and select |
| `Home` / `End` | Jump to first/last row |
| `Shift+Click` | Range selection |
| `Double-Click` | Open chat in browser |
