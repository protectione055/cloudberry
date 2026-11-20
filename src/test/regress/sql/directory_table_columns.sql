-- User-defined directory table columns follow the five built-in columns.
-- start_matchsubs
-- m/  \(seg\d+ .*? pid=\d+\)/
-- s/  \(seg\d+ .*? pid=\d+\)//
-- end_matchsubs
CREATE DIRECTORY TABLE dircols_legacy;
CREATE DIRECTORY TABLE dircols_empty ();
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

-- Both the old and extended schemas can receive file uploads.
COPY BINARY dircols_legacy FROM PROGRAM 'printf directory-table-test' 'legacy';
COPY BINARY dircols_empty FROM PROGRAM 'printf directory-table-test' 'empty';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file01' WITH TAG 'uploaded';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file02';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file03';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file04';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file05';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file06';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file07';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file08';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file09';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file10';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file11';
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'file12';
SELECT count(*) AS files,
       bool_and(owner_name IS NULL AND amount IS NULL AND created_at IS NULL
                AND metadata IS NULL AND labels IS NULL AND short_name IS NULL) AS initially_null
FROM dircols;
SELECT bool_and(size = octet_length(content)
                AND md5 = pg_catalog.md5(content)
                AND convert_from(content, 'UTF8') = 'directory-table-test') AS files_intact
FROM directory_table('dircols');

UPDATE dircols SET owner_name = 'alice', amount = 123.45,
    created_at = timestamp '2026-01-02 03:04:05',
    metadata = '{"department":"finance"}', labels = ARRAY['private', 'pdf'],
    short_name = 'file', tag = 'reviewed'
WHERE relative_path = 'file01';
SELECT relative_path, owner_name, amount, created_at, metadata, labels, short_name, tag
FROM dircols WHERE relative_path = 'file01';
-- Variable-length user values use ordinary table storage.
UPDATE dircols SET owner_name = repeat('x', 10000) WHERE relative_path = 'file02';
SELECT length(owner_name) FROM dircols WHERE relative_path = 'file02';
-- Values larger than a heap page require TOAST storage.
UPDATE dircols SET owner_name =
    (SELECT string_agg(md5(n::text), '' ORDER BY n) FROM generate_series(1, 3000) n)
WHERE relative_path = 'file02';
SELECT length(owner_name) FROM dircols WHERE relative_path = 'file02';
-- Copy an external TOAST value, then remove its original owning relation.
CREATE TABLE dircols_toast_source (value text) DISTRIBUTED REPLICATED;
INSERT INTO dircols_toast_source
SELECT string_agg(md5(n::text), '' ORDER BY n) FROM generate_series(1, 3000) n;
UPDATE dircols SET owner_name = s.value
FROM dircols_toast_source s WHERE relative_path = 'file02';
DROP TABLE dircols_toast_source;
VACUUM dircols;
SELECT length(owner_name), md5(owner_name) =
    (SELECT md5(string_agg(md5(n::text), '' ORDER BY n)) FROM generate_series(1, 3000) n) AS value_intact
FROM dircols WHERE relative_path = 'file02';
UPDATE dircols SET metadata = jsonb_build_object('large', owner_name),
    labels = ARRAY[owner_name] WHERE relative_path = 'file02';
SELECT length(metadata->>'large'), length(labels[1])
FROM dircols WHERE relative_path = 'file02';
BEGIN;
UPDATE dircols SET owner_name = repeat('changed', 20000) WHERE relative_path = 'file02';
ROLLBACK;
SELECT length(owner_name) FROM dircols WHERE relative_path = 'file02';
UPDATE dircols SET short_name = 'too long' WHERE relative_path = 'file01';

BEGIN;
UPDATE dircols SET owner_name = 'rolled back' WHERE relative_path = 'file01';
ROLLBACK;
SELECT owner_name FROM dircols WHERE relative_path = 'file01';
BEGIN;
COPY BINARY dircols FROM PROGRAM 'printf rollback-test' 'rolled-back';
UPDATE dircols SET metadata = '{"temporary":true}' WHERE relative_path = 'rolled-back';
ROLLBACK;
SELECT count(*) FROM dircols WHERE relative_path = 'rolled-back';
-- The same path can be uploaded again after rollback.
COPY BINARY dircols FROM PROGRAM 'printf directory-table-test' 'rolled-back';
SELECT remove_file('dircols', 'rolled-back');

-- A file and its metadata can also be committed together.
BEGIN;
COPY BINARY dircols FROM PROGRAM 'printf atomic-test' 'atomic';
UPDATE dircols SET owner_name = 'atomic' WHERE relative_path = 'atomic';
COMMIT;
SELECT owner_name FROM dircols WHERE relative_path = 'atomic';
SELECT remove_file('dircols', 'atomic');

-- System-maintained columns remain protected, including mixed updates.
UPDATE dircols SET relative_path = 'renamed' WHERE relative_path = 'file01';
UPDATE dircols SET size = 0 WHERE relative_path = 'file01';
UPDATE dircols SET last_modified = now() WHERE relative_path = 'file01';
UPDATE dircols SET md5 = 'changed', owner_name = 'bob' WHERE relative_path = 'file01';
INSERT INTO dircols (relative_path, owner_name) VALUES ('manual', 'alice');
DELETE FROM dircols WHERE relative_path = 'file01';
ALTER TABLE dircols ADD COLUMN extra text;
ALTER TABLE dircols DROP COLUMN owner_name;
ALTER TABLE dircols ALTER COLUMN owner_name TYPE integer;
ALTER TABLE dircols RENAME COLUMN owner_name TO owner;
SELECT owner_name, tag FROM dircols WHERE relative_path = 'file01';

-- Column-level privileges still apply to user-defined metadata.
SET client_min_messages = warning;
CREATE ROLE dircols_reader;
RESET client_min_messages;
GRANT SELECT ON dircols TO dircols_reader;
GRANT UPDATE (metadata) ON dircols TO dircols_reader;
SET ROLE dircols_reader;
UPDATE dircols SET metadata = '{"checked":true}' WHERE relative_path = 'file01';
UPDATE dircols SET owner_name = 'bob' WHERE relative_path = 'file01';
RESET ROLE;
SELECT metadata FROM dircols WHERE relative_path = 'file01';

-- Reject unsupported definitions before creating the relation or its storage.
CREATE DIRECTORY TABLE dircols_bad (size bigint);
CREATE DIRECTORY TABLE dircols_bad (extra text, extra integer);
CREATE DIRECTORY TABLE dircols_bad (extra text COLLATE "C");
CREATE DIRECTORY TABLE dircols_bad (extra text DEFAULT 'x');
CREATE DIRECTORY TABLE dircols_bad (extra text NOT NULL);
CREATE DIRECTORY TABLE dircols_bad (extra integer CHECK (extra > 0));
CREATE DIRECTORY TABLE dircols_bad (extra integer GENERATED ALWAYS AS (1) STORED);
CREATE DIRECTORY TABLE dircols_bad (extra integer GENERATED ALWAYS AS IDENTITY);
CREATE DIRECTORY TABLE dircols_bad (extra serial);
CREATE DIRECTORY TABLE dircols_bad (extra integer, UNIQUE (extra));
CREATE DIRECTORY TABLE dircols_bad (LIKE dircols);
CREATE DIRECTORY TABLE dircols_bad (extra void);
CREATE DOMAIN dircols_required AS text NOT NULL;
CREATE DOMAIN dircols_positive AS integer CHECK (VALUE > 0);
CREATE DOMAIN dircols_inherited AS dircols_required;
CREATE DIRECTORY TABLE dircols_bad (extra dircols_required);
CREATE DIRECTORY TABLE dircols_bad (extra dircols_positive);
CREATE DIRECTORY TABLE dircols_bad (extra dircols_inherited);
SELECT to_regclass('dircols_bad') IS NULL AS no_failed_table,
       to_regclass('dircols_bad_extra_seq') IS NULL AS no_failed_sequence;
DROP DOMAIN dircols_inherited;
DROP DOMAIN dircols_required;
DROP DOMAIN dircols_positive;

-- Unconstrained domains use the normal column type machinery.
CREATE DOMAIN dircols_plain AS text;
CREATE DOMAIN dircols_plain_child AS dircols_plain;
CREATE DIRECTORY TABLE dircols_domain (extra dircols_plain_child);
COPY BINARY dircols_domain FROM PROGRAM 'printf domain-test' 'domain';
SELECT extra IS NULL AS initially_null FROM dircols_domain;
UPDATE dircols_domain SET extra = 'domain metadata';
SELECT extra FROM dircols_domain;
-- ALTER DOMAIN must validate directory rows, including inherited domains.
ALTER DOMAIN dircols_plain ADD CONSTRAINT dircols_allowed CHECK (VALUE = 'allowed');
ALTER DOMAIN dircols_plain ADD CONSTRAINT dircols_has_value CHECK (VALUE IS NOT NULL) NOT VALID;
COPY BINARY dircols_domain FROM PROGRAM 'printf domain-test' 'rejected-check';
SELECT count(*) FROM dircols_domain WHERE relative_path = 'rejected-check';
ALTER DOMAIN dircols_plain VALIDATE CONSTRAINT dircols_has_value;
ALTER DOMAIN dircols_plain DROP CONSTRAINT dircols_has_value;
COPY BINARY dircols_domain FROM PROGRAM 'printf domain-test' 'null-row';
ALTER DOMAIN dircols_plain ADD CONSTRAINT dircols_has_value CHECK (VALUE IS NOT NULL);
DROP DIRECTORY TABLE dircols_domain WITH CONTENT;
DROP DOMAIN dircols_plain_child;
DROP DOMAIN dircols_plain;

-- The normal table column limit includes the five built-in columns.
DO $$
BEGIN
    EXECUTE 'CREATE DIRECTORY TABLE dircols_too_wide (' ||
        (SELECT string_agg('c' || n || ' integer', ',') FROM generate_series(1, 1596) n) || ')';
EXCEPTION WHEN too_many_columns THEN
    RAISE NOTICE 'column limit enforced';
END;
$$;

SELECT bool_and(size = octet_length(content) AND md5 = pg_catalog.md5(content)) AS files_intact
FROM directory_table('dircols');
-- File removal must find the system primary key among metadata indexes,
-- and delete rows containing external TOAST values.
CREATE INDEX dircols_short_name_idx ON dircols(short_name);
CREATE INDEX dircols_size_idx ON dircols(size);
COPY BINARY dircols FROM PROGRAM 'printf test' 'indexed';
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT relative_path FROM dircols WHERE size = 4;
RESET enable_seqscan;
RESET enable_bitmapscan;
SELECT remove_file('dircols', 'indexed');
SELECT remove_file('dircols', 'file02');
SELECT count(*) FROM dircols WHERE relative_path = 'file02';
DROP DIRECTORY TABLE dircols WITH CONTENT;
DROP ROLE dircols_reader;
DROP DIRECTORY TABLE dircols_legacy WITH CONTENT;
DROP DIRECTORY TABLE dircols_empty WITH CONTENT;

-- Exercise direct file ingestion on one segment in utility mode.
SELECT format('host=%s port=%s dbname=%s user=%s options=''-c gp_role=utility -c optimizer=off''',
              address, port, current_database(), current_user) AS conn
FROM gp_segment_configuration
WHERE content = 0 AND role = 'p' AND warehouseid = 0
\gset dircols_utility_
-- start_ignore
\connect -reuse-previous=off :dircols_utility_conn
-- end_ignore
CREATE DIRECTORY TABLE dircols_utility (metadata jsonb, labels integer[]);
COPY BINARY dircols_utility FROM PROGRAM 'printf utility-test' 'utility';
SELECT relative_path, metadata IS NULL AND labels IS NULL AS initially_null
FROM dircols_utility;
UPDATE dircols_utility SET metadata = '{"utility":true}', labels = ARRAY[1,2];
SELECT metadata, labels FROM dircols_utility;
SELECT size = octet_length(content) AND md5 = pg_catalog.md5(content) AS file_intact
FROM directory_table('dircols_utility');
UPDATE dircols_utility SET labels = ARRAY(SELECT n FROM generate_series(1, 20000) n);
SELECT array_length(labels, 1) FROM dircols_utility;
CREATE INDEX dircols_utility_metadata_idx ON dircols_utility USING gin(metadata);
SELECT remove_file_segment('dircols_utility', 'utility');
CREATE INDEX dircols_utility_size_idx ON dircols_utility(size);
COPY BINARY dircols_utility FROM PROGRAM 'printf test' 'indexed';
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT relative_path FROM dircols_utility WHERE size = 4;
RESET enable_seqscan;
RESET enable_bitmapscan;
SELECT remove_file_segment('dircols_utility', 'indexed');
CREATE DOMAIN dircols_utility_domain AS text;
CREATE DIRECTORY TABLE dircols_utility_domain_table (extra dircols_utility_domain);
ALTER DOMAIN dircols_utility_domain ADD CHECK (VALUE IS NOT NULL) NOT VALID;
COPY BINARY dircols_utility_domain_table FROM PROGRAM 'printf domain-test' 'rejected';
SELECT count(*) FROM dircols_utility_domain_table;
DROP DIRECTORY TABLE dircols_utility_domain_table WITH CONTENT;
DROP DOMAIN dircols_utility_domain;
BEGIN;
COPY BINARY dircols_utility FROM PROGRAM 'printf rollback-test' 'utility-rollback';
ROLLBACK;
SELECT count(*) FROM dircols_utility WHERE relative_path = 'utility-rollback';
DROP DIRECTORY TABLE dircols_utility WITH CONTENT;
