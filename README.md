# Claude-Chat-Deletion-Manager
Filter for and delete conversations 

Syntax       Example                  What it does
text         hello                    Substring match (original behavior)
foo|bar|baz  python|javascript|rust   OR search - matches any term
/pattern/    /\d{4}-\d{2}/            Full regex pattern
id:value     id:abc123                Search by single ID (partial match)
ids:a,b,c    ids:abc,def,ghi          Search multiple IDs (comma-separated)


# Find chats about Python OR JavaScript
python|javascript

# Find chats with dates like 2024-01
/\d{4}-\d{2}/

# Find specific chat by ID
id:550e8400-e29b

# Delete specific chats by ID - paste comma-separated IDs
ids:abc123,def456,ghi789
