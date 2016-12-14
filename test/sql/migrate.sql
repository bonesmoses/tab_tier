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

SELECT tab_tier.register_tier_root('tiertest', 'tier_test', 'dt');
SELECT tab_tier.bootstrap_tier_parts('tiertest', 'tier_test');

SELECT tab_tier.migrate_all_tiers();

SELECT count(*) FROM ONLY tier_test;

ROLLBACK;
