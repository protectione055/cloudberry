--
-- Basic tests for user-defined columns in directory tables
--
-- start_matchsubs
-- m/  \(seg\d+ .*? pid=\d+\)/
-- s/  \(seg\d+ .*? pid=\d+\)//
-- end_matchsubs

-- =====================================================================
-- 1. Creating directory tables with and without user-defined columns
-- =====================================================================
-- Existing syntax (no column list or empty list) still creates only the
-- five built-in columns.
CREATE DIRECTORY TABLE dircols_legacy;
CREATE DIRECTORY TABLE dircols_empty ();

-- User-defined columns follow the five built-in columns and are nullable.
CREATE DIRECTORY TABLE IF NOT EXISTS dircols (
    owner_name text,
    amount numeric(12,2),
    created_at timestamp,
    metadata jsonb,
    labels text[],
    short_name varchar(4)
);
CREATE DIRECTORY TABLE IF NOT EXISTS dircols (ignored integer);

SELECT attnum, attname, format_type(atttypid, atttypmod), attnotnull
FROM pg_attribute
WHERE attrelid = 'dircols'::regclass AND attnum > 0
ORDER BY attnum;

SELECT count(*) = 5 AS legacy_columns
FROM pg_attribute WHERE attrelid = 'dircols_legacy'::regclass AND attnum > 0;
SELECT count(*) = 5 AS empty_columns
FROM pg_attribute WHERE attrelid = 'dircols_empty'::regclass AND attnum > 0;

-- =====================================================================
-- 2. Uploading files (user-defined columns default to NULL)
-- =====================================================================
COPY BINARY dircols_legacy FROM PROGRAM 'printf directory-table-test' 'legacy';
COPY BINARY dircols_empty FROM PROGRAM 'printf directory-table-test' 'empty';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file01' WITH TAG 'uploaded';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file02';

-- COPY with column lists or WHERE clauses is not supported on directory tables.
COPY BINARY dircols (owner_name) FROM PROGRAM 'printf directory-table-test' 'column-list';
COPY BINARY dircols (owner_name) TO STDOUT 'file01';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'filtered' WHERE false;

SELECT relative_path, tag, owner_name, amount, created_at, metadata, labels, short_name
FROM dircols
ORDER BY relative_path;

-- File content remains readable via directory_table().
SELECT bool_and(size = octet_length(content)
                AND md5 = pg_catalog.md5(content)
                AND convert_from(content, 'UTF8') = 'directory-table-test') AS files_intact
FROM directory_table('dircols');

-- =====================================================================
-- 3. Updating user-defined metadata and tag
-- =====================================================================
UPDATE dircols
SET owner_name = 'alice',
    amount = 123.45,
    created_at = timestamp '2026-01-02 03:04:05',
    metadata = '{"department":"finance"}',
    labels = ARRAY['private', 'pdf'],
    short_name = 'file',
    tag = 'reviewed'
WHERE relative_path = 'file01';

SELECT relative_path, owner_name, amount, created_at, metadata, labels, short_name, tag
FROM dircols
WHERE relative_path = 'file01';

-- Normal column type checks apply on UPDATE.
UPDATE dircols SET short_name = 'too long' WHERE relative_path = 'file01';

-- File upload and metadata update work together in a transaction.
BEGIN;
COPY BINARY dircols FROM PROGRAM 'printf atomic-test' 'atomic';
UPDATE dircols SET owner_name = 'atomic' WHERE relative_path = 'atomic';
COMMIT;
SELECT owner_name FROM dircols WHERE relative_path = 'atomic';

BEGIN;
COPY BINARY dircols FROM PROGRAM 'printf rollback-test' 'rolled-back';
UPDATE dircols SET metadata = '{"temporary":true}' WHERE relative_path = 'rolled-back';
ROLLBACK;
SELECT count(*) FROM dircols WHERE relative_path = 'rolled-back';

-- A domain used by a directory table must remain without a default.
CREATE DOMAIN dircols_label AS text;
CREATE DIRECTORY TABLE dircols_defaults (label dircols_label);
ALTER DOMAIN dircols_label SET DEFAULT NULL;
ALTER DOMAIN dircols_label DROP DEFAULT;
ALTER DOMAIN dircols_label SET DEFAULT 'domain default';
COPY BINARY dircols_defaults FROM PROGRAM 'printf directory-table-test' 'direct';
SELECT label IS NULL AS uploaded_null FROM dircols_defaults;
UPDATE dircols_defaults SET label = 'changed';
UPDATE dircols_defaults SET label = DEFAULT WHERE relative_path = 'direct';
SELECT label IS NULL AS updated_null FROM dircols_defaults;
DROP DIRECTORY TABLE dircols_defaults WITH CONTENT;
CREATE TABLE dircols_label_arrays (labels dircols_label[]) DISTRIBUTED RANDOMLY;
ALTER DOMAIN dircols_label SET DEFAULT 'domain default';
CREATE DIRECTORY TABLE dircols_bad (label dircols_label);
DROP TABLE dircols_label_arrays;
DROP DOMAIN dircols_label;

-- =====================================================================
-- 4. Protecting system-maintained columns and disallowing INSERT/DELETE
-- =====================================================================
UPDATE dircols SET relative_path = 'renamed' WHERE relative_path = 'file01';
UPDATE dircols SET size = 0 WHERE relative_path = 'file01';
UPDATE dircols SET last_modified = now() WHERE relative_path = 'file01';
UPDATE dircols SET md5 = 'changed', owner_name = 'bob' WHERE relative_path = 'file01';

INSERT INTO dircols (relative_path, owner_name) VALUES ('manual', 'alice');
DELETE FROM dircols WHERE relative_path = 'file01';

-- =====================================================================
-- 5. Removing files
-- =====================================================================
SELECT remove_file('dircols', 'atomic');
SELECT remove_file('dircols', 'file02');
SELECT relative_path, owner_name, tag FROM dircols ORDER BY relative_path;

-- =====================================================================
-- 6. Rejecting unsupported column definitions and schema alterations
-- =====================================================================
-- Duplicate built-in or user column names
CREATE DIRECTORY TABLE dircols_bad (size bigint);
CREATE DIRECTORY TABLE dircols_bad (extra text, extra integer);

-- Unsupported column options (only column name and data type are allowed)
CREATE DIRECTORY TABLE dircols_bad (extra text DEFAULT 'x');
CREATE DIRECTORY TABLE dircols_bad (extra text NOT NULL);
CREATE DIRECTORY TABLE dircols_bad (extra integer CHECK (extra > 0));
CREATE DIRECTORY TABLE dircols_bad (extra text COLLATE "C");
CREATE DIRECTORY TABLE dircols_bad (extra serial);
CREATE DIRECTORY TABLE dircols_bad (extra integer, UNIQUE (extra));
CREATE DIRECTORY TABLE dircols_bad (LIKE dircols);

-- Schema changes on user-defined columns and distribution policy are not supported
ALTER TABLE dircols ADD COLUMN extra text;
ALTER TABLE dircols DROP COLUMN owner_name;
ALTER TABLE dircols ALTER COLUMN owner_name TYPE integer;
ALTER TABLE dircols RENAME COLUMN owner_name TO owner;
ALTER TABLE dircols SET DISTRIBUTED BY (owner_name);

-- =====================================================================
-- 7. Cleanup
-- =====================================================================
DROP DIRECTORY TABLE dircols WITH CONTENT;
DROP DIRECTORY TABLE dircols_legacy WITH CONTENT;
DROP DIRECTORY TABLE dircols_empty WITH CONTENT;
