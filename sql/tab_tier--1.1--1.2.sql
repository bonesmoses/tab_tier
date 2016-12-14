--------------------------------------------------------------------------------
-- CREATE FUNCTIONS
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION bootstrap_tier_parts(
  sSchema   VARCHAR,
  sTable    VARCHAR,
  bFuture   BOOLEAN DEFAULT FALSE
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
  -- with the maximum value found in the root table after adding the 
  -- retention period to counter the assumed retention window.

  IF bFuture THEN
      EXECUTE
        'SELECT max(' || quote_ident(rRoot.date_column) || ')
           FROM ' || quote_ident(sSchema) || '.' || quote_ident(sTable)
      INTO dFinal;
      dFinal = dFinal + rRoot.root_retain;
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

CREATE OR REPLACE FUNCTION drop_archived_tiers()
RETURNS VOID AS $$
DECLARE
  sSchema VARCHAR;
  sTable  VARCHAR;
BEGIN

  -- Simply loop through all archived partitions and invoke a drop command.

  FOR sSchema, sTable IN
      SELECT part_schema, part_table
        FROM @extschema@.tier_part
       WHERE is_archived
         FOR UPDATE
  LOOP
    BEGIN
      RAISE NOTICE 'Dropping archived partition: %...', sTable;
      EXECUTE 'DROP TABLE ' || quote_ident(sSchema) || '.' ||
              quote_ident(sTable);

      DELETE FROM @extschema@.tier_part
       WHERE part_schema = sSchema
         AND part_table = sTable;

    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Could not drop %! Skipping.', sTable;
      CONTINUE;
    END;
  END LOOP;

END;
$$ LANGUAGE plpgsql VOLATILE;

--------------------------------------------------------------------------------
-- GRANT USAGE
--------------------------------------------------------------------------------

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA @extschema@ FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA @extschema@ TO tab_tier_role;
