## Search Syntax

| Syntax | Example | Description |
|--------|---------|-------------|
| `text` | `hello` | Substring match (default) |
| `foo\|bar\|baz` | `python\|javascript\|rust` | OR search - matches any term |
| `/pattern/` | `/\d{4}-\d{2}/` | Regular expression |
| `id:value` | `id:abc123` | Search by single ID (partial match) |
| `ids:a,b,c` | `ids:abc,def,ghi` | Search multiple IDs (comma-separated) |

## Examples

Find chats about Python OR JavaScript:
```
python|javascript
```

Find chats with dates like 2024-01:
```
/\d{4}-\d{2}/
```

Find specific chat by ID:
```
id:550e8400-e29b
```

Delete specific chats by ID:
```
ids:abc123,def456,ghi789
```
