-- fts5-setup.sql
-- FTS5 full-text search setup with automatic sync triggers.
-- Adapt table/column names to your schema.

-- ═══════════════════════════════════════════════════════════════
-- STEP 1: Create the content table (your regular data table)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS documents (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    author TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
) STRICT;

-- ═══════════════════════════════════════════════════════════════
-- STEP 2: Create the FTS5 virtual table
-- ═══════════════════════════════════════════════════════════════

-- content= points to the source table for "contentless" mode (stores data once).
-- content_rowid= maps the FTS rowid to the source table's primary key.
-- tokenize: porter adds English stemming; unicode61 handles Unicode case folding.
CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
    title,
    body,
    author,
    content=documents,
    content_rowid=id,
    tokenize='porter unicode61 remove_diacritics 2'
);

-- ═══════════════════════════════════════════════════════════════
-- STEP 3: Sync triggers (keep FTS index in sync with content table)
-- ═══════════════════════════════════════════════════════════════

-- After INSERT: add the new row to the FTS index
CREATE TRIGGER IF NOT EXISTS documents_fts_insert
AFTER INSERT ON documents
BEGIN
    INSERT INTO documents_fts(rowid, title, body, author)
    VALUES (new.id, new.title, new.body, new.author);
END;

-- After DELETE: remove the old row from the FTS index
-- Note: FTS5 delete requires re-inserting with the special 'delete' command
-- and the OLD values, so the index knows what to remove.
CREATE TRIGGER IF NOT EXISTS documents_fts_delete
AFTER DELETE ON documents
BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, title, body, author)
    VALUES ('delete', old.id, old.title, old.body, old.author);
END;

-- After UPDATE: delete old entry, insert new entry
CREATE TRIGGER IF NOT EXISTS documents_fts_update
AFTER UPDATE ON documents
BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, title, body, author)
    VALUES ('delete', old.id, old.title, old.body, old.author);
    INSERT INTO documents_fts(rowid, title, body, author)
    VALUES (new.id, new.title, new.body, new.author);
END;

-- ═══════════════════════════════════════════════════════════════
-- STEP 4: Example queries
-- ═══════════════════════════════════════════════════════════════

-- Basic full-text search
-- SELECT d.*, bm25(documents_fts) AS rank
-- FROM documents_fts f
-- JOIN documents d ON d.id = f.rowid
-- WHERE documents_fts MATCH 'search terms'
-- ORDER BY rank
-- LIMIT 20;

-- Search with column filter (search only title)
-- SELECT d.*
-- FROM documents_fts f
-- JOIN documents d ON d.id = f.rowid
-- WHERE documents_fts MATCH 'title:sqlite';

-- Boolean search
-- SELECT d.*
-- FROM documents_fts f
-- JOIN documents d ON d.id = f.rowid
-- WHERE documents_fts MATCH 'sqlite AND (performance OR optimization) NOT legacy';

-- Phrase search
-- SELECT d.*
-- FROM documents_fts f
-- JOIN documents d ON d.id = f.rowid
-- WHERE documents_fts MATCH '"write ahead log"';

-- Prefix search
-- SELECT d.*
-- FROM documents_fts f
-- JOIN documents d ON d.id = f.rowid
-- WHERE documents_fts MATCH 'optim*';

-- Highlight matching terms
-- SELECT highlight(documents_fts, 0, '<mark>', '</mark>') AS title_highlighted,
--        highlight(documents_fts, 1, '<mark>', '</mark>') AS body_highlighted
-- FROM documents_fts
-- WHERE documents_fts MATCH 'query terms';

-- Extract snippet around match
-- SELECT snippet(documents_fts, 1, '<b>', '</b>', '...', 32) AS excerpt
-- FROM documents_fts
-- WHERE documents_fts MATCH 'query';

-- BM25 ranking with column weights (title=10, body=1, author=5)
-- SELECT d.*, bm25(documents_fts, 10.0, 1.0, 5.0) AS rank
-- FROM documents_fts f
-- JOIN documents d ON d.id = f.rowid
-- WHERE documents_fts MATCH 'query'
-- ORDER BY rank
-- LIMIT 20;

-- ═══════════════════════════════════════════════════════════════
-- STEP 5: Maintenance
-- ═══════════════════════════════════════════════════════════════

-- Optimize the FTS index (merge internal segments for faster queries).
-- Run periodically during maintenance windows.
-- INSERT INTO documents_fts(documents_fts) VALUES ('optimize');

-- Rebuild the entire FTS index from the content table.
-- Use after bulk imports or if the index gets out of sync.
-- INSERT INTO documents_fts(documents_fts) VALUES ('rebuild');

-- Integrity check: verify FTS index matches content table.
-- Returns an error message if mismatched, nothing if OK.
-- INSERT INTO documents_fts(documents_fts, rank) VALUES ('integrity-check', 1);
