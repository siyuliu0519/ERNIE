-- This script updates the wos_references with data from
-- newly-downloaded files. Specifically:

--     1. Find update_records: copy current records with WOS IDs in new table
--        to update history table: uhs_wos_publications.
--     2a. Delete records in main table that have same source_id in new table,
--         but cited_source_uid not in new table.
--     2b. Replace records in main table with records that have same
--         source_id & cited_source_uid in new table.
--     2c. Delete records in new table that have same source_id &
--         cited_source_uid in main table.
--     2d. Insert the remaining of new table to main table.
--     3. Truncate the new tables: new_wos_*.
--     4. Record to log table: update_log_wos.

-- Relevant main tables:
--     wos_references
-- Usage: psql -d ernie -f wos_update_ref_tables.sql
--        -v new_ref_chunk=$new_chunk
--        where $new_chunk are variables tablename passed by a shell script.

-- Author: Lingtian "Lindsay" Wan
-- Create Date: 06/06/2016
-- Modified: 06/07/2016, Lindsay Wan, added source_filename column
--           08/05/2016, Lindsay Wan, disabled hashjoin & mergejoin, added indexes
--           11/21/2016, Lindsay Wan, set search_path to public and lindsay
--           02/22/2017, Lindsay Wan, set search_path to public and samet
--           08/08/2017, Samet Keserci, index and tablespace are revised according to wos smokeload.

\set ON_ERROR_STOP on
\set ECHO all

-- Set temporary tablespace for calculation.
SET log_temp_files = 0;
--set enable_seqscan='off';
--set temp_tablespaces = 'temp_tbs';
--set enable_hashjoin = 'off';
--set enable_mergejoin = 'off';

-- Create index on the chunk of new table.
CREATE INDEX new_ref_chunk_idx
  ON :new_ref_chunk USING BTREE (source_id, cited_source_uid) TABLESPACE indexes;

-- Create a temp table to store WOS IDs from the update file.
DROP TABLE IF EXISTS temp_update_ref_wosid;
CREATE TABLE temp_update_ref_wosid TABLESPACE wos AS
  SELECT DISTINCT source_id
  FROM :new_ref_chunk;
CREATE INDEX temp_update_ref_wosid_idx
  ON temp_update_ref_wosid USING HASH (source_id) TABLESPACE indexes;

ANALYZE temp_update_ref_wosid;

-- Create a temporary table to store update WOS IDs that already exist in WOS
-- tables.
DROP TABLE IF EXISTS temp_replace_ref_wosid;
CREATE TABLE temp_replace_ref_wosid TABLESPACE wos AS
  SELECT DISTINCT a.source_id
  FROM temp_update_ref_wosid a INNER JOIN wos_references b ON a.source_id = b.source_id;
CREATE INDEX temp_replace_ref_wosid_idx
  ON temp_replace_ref_wosid USING HASH (source_id) TABLESPACE indexes;

ANALYZE temp_replace_ref_wosid;

-- Update table: wos_references
\echo ***UPDATING TABLE: wos_references
-- Create a temp table to store ids that need to be dealt with.
DROP TABLE IF EXISTS temp_wos_reference_1;
CREATE TABLE temp_wos_reference_1 TABLESPACE wos AS
  SELECT a.source_id, a.cited_source_uid
  FROM wos_references a
  WHERE exists(SELECT 1
               FROM temp_replace_ref_wosid b
               WHERE a.source_id = b.source_id);
CREATE INDEX temp_wos_reference_1_idx
  ON temp_wos_reference_1 USING BTREE (source_id, cited_source_uid) TABLESPACE indexes;

ANALYZE temp_wos_reference_1;

-- Copy records to be replaced or deleted to update history table.
INSERT INTO uhs_wos_references (SELECT id, source_id, cited_source_uid, cited_title, cited_work, cited_author,
  cited_year, cited_page, created_date, last_modified_date, source_filename
FROM wos_references a
WHERE exists(SELECT *
             FROM temp_wos_reference_1 b
             WHERE a.source_id = b.source_id AND a.cited_source_uid = b.cited_source_uid));
-- Delete records with source_id in new table, but cited_source_uid not in.
DELETE FROM wos_references a
USING temp_replace_ref_wosid b
WHERE a.source_id = b.source_id AND NOT exists(SELECT 1
                                               FROM :new_ref_chunk c
                                               WHERE
                                                 a.source_id = c.source_id AND a.cited_source_uid = c.cited_source_uid);
-- Replace records with new records that have same source_id & cited_source_uid.
UPDATE wos_references AS a
SET
  (cited_title, cited_work, cited_author, cited_year, cited_page, created_date, last_modified_date, source_filename) = (b.cited_title, b.cited_work, b.cited_author, b.cited_year, b.cited_page, b.created_date, b.last_modified_date, b.source_filename) FROM
  :new_ref_chunk b
WHERE a.source_id = b.source_id AND a.cited_source_uid = b.cited_source_uid;
-- Delete records in new table that have already replaced main table records.
DELETE FROM :new_ref_chunk a
USING wos_references b
WHERE a.source_id = b.source_id AND a.cited_source_uid = b.cited_source_uid;
-- Add remaining records (new) from new table to main table.
INSERT INTO wos_references (id, source_id, cited_source_uid, cited_title, cited_work, cited_author, cited_year, cited_page, created_date, last_modified_date, source_filename)
  SELECT *
  FROM :new_ref_chunk;
-- Drop the chunked new table.
DROP TABLE :new_ref_chunk;
