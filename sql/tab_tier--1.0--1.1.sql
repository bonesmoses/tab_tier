--------------------------------------------------------------------------------
-- CREATE FUNCTIONS
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION bootstrap_tier_parts(
  sSchema   VARCHAR,
  sTable    VARCHAR,
  bFuture   BOOLEAN
)
RETURNS VOID AS $$
DECLARE
  rRoot @extschema@.tier_root%ROWTYPE;

  dStart DATE;
  dCurrent DATE;
  dFinal DATE := CURRENT_DATE;
BEGIN

  -- Retrieve the root definition. That will define all of our crazy work
  -- in creating potentially dozens of partitions.

  SELECT INTO rRoot *
    FROM @extschema@.tier_root
   WHERE root_schema = sSchema
     AND root_table = sTable;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not bootstrap %. Not found!', quote_ident(sTable);
  END IF;

  -- Get the smallest known value from our source table for the date_column.
  -- This will determine the date of our earliest partition. If the root
  -- table would have no partitions, just skip it.

  EXECUTE
    'SELECT min(' || quote_ident(rRoot.date_column) || ')
       FROM ' || quote_ident(sSchema) || '.' || quote_ident(sTable)
  INTO dStart;

  IF dStart IS NULL THEN
    RETURN;
  END IF;

  -- If we're asked to create future partitions, replace the stopping date
  -- with the maximum value found in the root table.

  IF bFuture THEN
      EXECUTE
        'SELECT max(' || quote_ident(rRoot.date_column) || ')
           FROM ' || quote_ident(sSchema) || '.' || quote_ident(sTable)
      INTO dFinal;
      dFinal = dFinal - rRoot.part_period;
  END IF;

  -- Insert a "dummy" row into the tier partition tracking table, one
  -- part_period older than the oldest known date in the source. This record
  -- will create an artificial time gap that we can use extend_tier_root
  -- to fill in the "missing" partitions.

  INSERT INTO @extschema@.tier_part (tier_root_id, part_schema,
         part_table, check_start, check_stop)
  VALUES (rRoot.tier_root_id, 'strap', 'strap', dStart - rRoot.part_period,
          dStart);

  -- Loop creating partitions until we have enough to satisfy an insert
  -- only one day older than root_retain, minus the width of one period.
  -- This ensures at least one extra partition exists if the date rolls
  -- over, and is what cap_tier_partitions would do in any case.

  dCurrent = dStart;

  WHILE dCurrent <= dFinal - rRoot.root_retain + rRoot.part_period
  LOOP
    PERFORM @extschema@.extend_tier_root(sSchema, sTable);
    dCurrent = dCurrent + rRoot.part_period;
  END LOOP;

  -- Finally, delete the bootstrap row we created in the partition tracker.

  DELETE FROM @extschema@.tier_part
   WHERE tier_root_id = rRoot.tier_root_id
     AND part_table = 'strap';

END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION _copy_indexes(VARCHAR, VARCHAR, VARCHAR, 
                                           VARCHAR)
RETURNS VOID AS $$
DECLARE
  sSchema     ALIAS FOR $1;
  sSource     ALIAS FOR $2;
  sNSPTarget  ALIAS FOR $3;
  sTarget     ALIAS FOR $4;

  rIndex RECORD;
  sIndex VARCHAR;
  nCounter INT := 1;
BEGIN

  -- Cascade every known index from the source table to the target.
  -- This should not include primary keys because we may have manually added
  -- such a beast with a constraint cascade. The only exception is the
  -- partition column.

  FOR rIndex IN SELECT pg_get_indexdef(i.oid) AS indexdef, x.indisprimary,
                       CASE WHEN x.indisunique = True
                            THEN 'u' ELSE 'i' END AS indtype
                  FROM pg_index x
                  JOIN pg_class c ON (c.oid = x.indrelid)
                  JOIN pg_class i ON (i.oid = x.indexrelid)
                  JOIN pg_namespace n ON (n.oid = c.relnamespace)
                 WHERE n.nspname = sSchema
                   AND c.relname = sSource
                 GROUP BY 1, 2, 3
  LOOP

    -- Generate an index name that isn't *quite* as long, since all child
    -- tables will have a bunch of extra cruft added that might get
    -- truncated.

    sIndex = rIndex.indtype || 'dx_' || 
             regexp_replace(sTarget, '([a-z]{1,4})[a-z]*?_?',
                            '\1_', 'ig') || nCounter;

    rIndex.indexdef = regexp_replace(rIndex.indexdef,
      'INDEX [\w\.]+ ',
      'INDEX ' || sIndex || ' ');

    rIndex.indexdef = regexp_replace(rIndex.indexdef,
      ' ON [\w\.]+ ',
      ' ON ' || sNSPTarget || '.' || sTarget || ' ');

    EXECUTE rIndex.indexdef;
    
    nCounter := nCounter + 1;
    
  END LOOP;

END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION flush_all_tiers()
RETURNS VOID AS $$
DECLARE
  rPart @extschema@.tier_root%ROWTYPE;
BEGIN

  -- Simply loop through all known root tables.
  -- In all cases, call the flush routine. That routine will push data to
  -- all existing partitions from the root table.

  FOR rPart IN SELECT * FROM @extschema@.tier_root
  LOOP
    BEGIN
      PERFORM @extschema@.flush_tier_data(rPart.root_schema,
        rPart.root_table);

    -- If one tier barfs, there's no reason *all* of them should.

    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Problem encountered with %! Skipping.', rPart.root_table;
      CONTINUE;
    END;

  END LOOP;

END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION flush_tier_data(
  sSchema   VARCHAR,
  sTable    VARCHAR
)
RETURNS VOID AS $$
DECLARE
  sPart VARCHAR;
BEGIN

  -- Given the root table, snag all non-archived partitions. We can simply
  -- call the basic migration function and let it do all of the heavy lifting.

  FOR sPart IN SELECT replace(p.part_table, sTable || '_part_', '')
                 FROM tab_tier.tier_root r
                 JOIN tab_tier.tier_part p USING (tier_root_id)
                WHERE root_schema = sSchema
                  AND root_table = sTable
                  AND NOT is_archived
  LOOP
    BEGIN
      PERFORM @extschema@.migrate_tier_data(sSchema, sTable, sPart, FALSE, TRUE);

    -- If one partition barfs, there's no reason *all* of them should.

    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Problem encountered with %! Skipping.', rPart.root_table;
      CONTINUE;
    END;

  END LOOP;

END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION @extschema@.migrate_tier_data(
  sSchema   VARCHAR,
  sTable    VARCHAR,
  sPart     VARCHAR DEFAULT NULL,
  bAnalyze  BOOLEAN DEFAULT TRUE,
  bAll      BOOLEAN DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
  rRoot @extschema@.tier_root%ROWTYPE;
  rPart @extschema@.tier_part%ROWTYPE;

  sColList VARCHAR;
  sSQL VARCHAR;
  nCount BIGINT;
BEGIN

  RAISE NOTICE 'Migrating Older % Data', sTable;

  -- Retrieve the root definition and the most recent partition definition
  -- where the root_retain root date falls between the check ranges.
  -- We'll need these to identify data being copied from the parent table
  -- to the correct partition.

  SELECT INTO rRoot *
    FROM @extschema@.tier_root
   WHERE root_schema = sSchema
     AND root_table = sTable;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not migrate (%). Not found!', quote_ident(sTable);
  END IF;

  -- If we were not passed a specific partition, get the boundaries from the
  -- partition that's just slightly older than root_retain. Otherwise, we
  -- were asked to target a specific partition, and we want its information.

  IF sPart IS NULL THEN
    SELECT INTO rPart *
      FROM @extschema@.tier_part
     WHERE tier_root_id = rRoot.tier_root_id
       AND check_start <= CURRENT_DATE - rRoot.root_retain
       AND NOT is_archived
     ORDER BY check_start DESC
     LIMIT 1;
  ELSE
    SELECT INTO rPart *
      FROM @extschema@.tier_part
     WHERE tier_root_id = rRoot.tier_root_id
       AND part_table = sTable || '_part_' || 
                        regexp_replace(sPart, '\D', '', 'g')
       AND NOT is_archived;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not data shift (%). Partition missing.',
          quote_ident(sTable);
  END IF;

  -- Now we just insert all rows that fall between the check constraints of the
  -- target partition we identified earlier. If rows fall outside these bounds,
  -- it's probably better that they be moved manually anyway, since they were
  -- likely added to the table for a date before the active partition.
  -- We can also set the snapshot date now, so we know when the data was moved.
  -- Again, we're avoiding a trigger to set this to reduce overhead.

  RAISE NOTICE ' * Copying data to new tier.';

  SELECT INTO sColList string_agg(a.attname::varchar, ', ')
    FROM pg_attribute a
   WHERE a.attrelid = (sSchema || '.' || sTable)::regclass
     AND a.attnum > 0;

  sSQL =
    'INSERT INTO ' || quote_ident(rPart.part_schema) || '.' ||
                      quote_ident(rPart.part_table) || 
            ' ( ' || sColList || ', snapshot_dt)
     SELECT ' || sColList || ', now()
       FROM ONLY ' || quote_ident(sSchema) || '.' || quote_ident(sTable) || '
      WHERE ' || quote_ident(rRoot.date_column) || ' >= ' ||
                 quote_literal(rPart.check_start::text) || '
        AND ' || quote_ident(rRoot.date_column) || ' < ' ||
                 quote_literal(rPart.check_stop::text);

  IF NOT bALL THEN
    sSQL = sSQL || '
        AND ' || quote_ident(rRoot.date_column) || ' < CURRENT_DATE - ' ||
                 quote_literal(rRoot.root_retain::text) || '::interval';
  END IF;

  EXECUTE sSQL;

  -- Here is where we'll insert an optimization shortcut. If all the rows
  -- we copied are the *only* rows to move, we can truncate the root table
  -- immediately and skip the slow delete operation.

  EXECUTE
    'SELECT count(*)
       FROM ONLY ' || quote_ident(sSchema) || '.' || quote_ident(sTable)
    INTO nCount;

  IF nCount < 1 THEN
    RAISE NOTICE ' * Truncating data from old tier.';

    EXECUTE 'TRUNCATE TABLE ONLY ' || quote_ident(sSchema) || '.' || 
            quote_ident(sTable);

  -- Or, once the rows are copied, it should be safe to delete them from the
  -- source. Since all children inherit from the main table, we want to
  -- *ensure* to use the ONLY keyword so we don't delete from all of the
  -- other partitions as well.

  ELSE 
    RAISE NOTICE ' * Deleting data from old tier.';

    sSQL =
      'DELETE FROM
         ONLY ' || quote_ident(sSchema) || '.' || quote_ident(sTable) || '
        WHERE ' || quote_ident(rRoot.date_column) || ' >= ' ||
                   quote_literal(rPart.check_start::text) || '
          AND ' || quote_ident(rRoot.date_column) || ' < ' ||
                   quote_literal(rPart.check_stop::text);

    IF NOT bALL THEN
      sSQL = sSQL || '
            AND ' || quote_ident(rRoot.date_column) || ' < CURRENT_DATE - ' ||
                     quote_literal(rRoot.root_retain::text) || '::interval';
    END IF;

    EXECUTE sSQL;

  END IF;

  -- Last but not least, analyze our source table because we probably
  -- invalidated the last collected statistics.

  IF bAnalyze THEN
    RAISE NOTICE ' * Updating statistics.';

    EXECUTE 'ANALYZE ' || quote_ident(sSchema) || '.' || quote_ident(sTable);
    EXECUTE 'ANALYZE ' || quote_ident(rPart.part_schema) || '.' || 
            quote_ident(rPart.part_table);
  END IF;

END;
$$ LANGUAGE plpgsql VOLATILE;

--------------------------------------------------------------------------------
-- GRANT USAGE
--------------------------------------------------------------------------------

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA @extschema@ FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA @extschema@ TO tab_tier_role;
