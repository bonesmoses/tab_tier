\set ECHO none

BEGIN;
\set ECHO all

CREATE EXTENSION tab_tier;

CREATE SCHEMA tiertest;

SET search_path TO tiertest;

CREATE TABLE tier_test (foo INT, dt TIMESTAMP WITH TIME ZONE);

INSERT INTO tier_test
SELECT a.id, '2016-12-15'::DATE - (a.id::TEXT || 'd')::INTERVAL
  FROM generate_series(1, 200) a (id);

UPDATE tab_tier.tier_part
   SET is_archived = TRUE
 WHERE check_start < '2016-12-15'::DATE - INTERVAL '5 months';

SELECT tab_tier.drop_archived_tiers();

SELECT count(*)
  FROM tab_tier.tier_part
 WHERE part_schema = 'tiertest';

SELECT count(*)
  FROM pg_tables
 WHERE schemaname = 'tiertest'
   AND tablename LIKE '%\_part\_%';

ROLLBACK;
