/**
 * Author: sthomas@peak6.com
 * Created at: Fri, 20 Feb 2015 08:15:55 -0600
 *
 * Several tables can be spread across several data storage tiers. Tiers can
 * consist of tablespaces with varying performance characteristics, or foreign
 * servers meant to be accessible, but not generally by the platform. These
 * types of tiers need a system to manage migration between data layers that
 * will not adversely affect platform performance.
 *
 * This library handles all maintenance in creating new tier partitions and
 * data ushering between partition segments.
 */

\echo Use "CREATE EXTENSION pg_tier;" to load this file. \quit

--------------------------------------------------------------------------------
-- PREPARE EXTENSION
--------------------------------------------------------------------------------

SET client_min_messages = warning;
SET LOCAL search_path TO @extschema@;

--------------------------------------------------------------------------------
-- CREATE TABLES
--------------------------------------------------------------------------------

CREATE TABLE tier_config
(
  config_id    SERIAL     NOT NULL  PRIMARY KEY,
  config_name  VARCHAR    NOT NULL  UNIQUE,
  setting      VARCHAR    NOT NULL,
  is_default   BOOLEAN    NOT NULL  DEFAULT False,
  created_dt   TIMESTAMP  NOT NULL  DEFAULT now(),
  modified_dt  TIMESTAMP  NOT NULL  DEFAULT now()
);

SELECT pg_catalog.pg_extension_config_dump('tier_config',
  'WHERE NOT is_default');

CREATE TABLE tier_root
(
  tier_root_id     SERIAL     NOT NULL  PRIMARY KEY,
  root_schema      VARCHAR    NOT NULL,
  root_table       VARCHAR    NOT NULL,
  date_column      VARCHAR    NULL,
  part_period      INTERVAL   NOT NULL,
  tier_proc        VARCHAR    NULL,
  part_tablespace  VARCHAR    NOT NULL,
  root_retain      INTERVAL   NOT NULL,
  lts_target       VARCHAR    NULL,
  lts_threshold    INTERVAL   NULL,
  is_default       BOOLEAN    NOT NULL  DEFAULT False,
  created_dt       TIMESTAMP  NOT NULL  DEFAULT now(),
  modified_dt      TIMESTAMP  NOT NULL  DEFAULT now()
);

SELECT pg_catalog.pg_extension_config_dump('tier_root',
  'WHERE NOT is_default');

CREATE TABLE tier_part
(
  tier_part_id  SERIAL     NOT NULL  PRIMARY KEY,
  tier_root_id  INT        NOT NULL,
  part_schema   VARCHAR    NOT NULL,
  part_table    VARCHAR    NOT NULL,
  check_start   TIMESTAMP  NOT NULL,
  check_stop    TIMESTAMP  NOT NULL,
  is_default    BOOLEAN    NOT NULL  DEFAULT False,
  created_dt    TIMESTAMP  NOT NULL,
  modified_dt   TIMESTAMP  NOT NULL
);

SELECT pg_catalog.pg_extension_config_dump('tier_part',
  'WHERE NOT is_default');

ALTER TABLE tier_part
  ADD CONSTRAINT fk_tier_part_root
      FOREIGN KEY (tier_root_id)
      REFERENCES tier_root (tier_root_id)
   ON DELETE CASCADE;

--------------------------------------------------------------------------------
-- CREATE FUNCTIONS
--------------------------------------------------------------------------------

/**
 * Register a user who is allowed to use or access pg_tier objects.
 *
 * Because pg_tier requires several management functions, granting usage is
 * somewhat cumbersome. This function exists as a shortcut for the user who
 * created the pg_tier extension to hand management to other users.
 * Functions for this include:
 *
 *  - bootstrap_tier_parts
 *  - cap_tier_partitions
 *  - extend_tier_root
 *  - get_tier_config
 *  - initialize_tier_part
 *  - migrate_all_tiers
 *  - migrate_tier_data
 *  - register_tier_root
 *  - set_tier_config
 *  - toggle_tier_partitions
 *  - unregister_table
 *
 * Table select permission includes:
 *
 *  - tier_config
 *  - tier_root
 *  - tier_part
 *
 * We suggest using a role for "admin" class users to avoid micromanagement.
 *
 * @param user_name  String user or role to delegate as tier admin.
 */
CREATE OR REPLACE FUNCTION add_tier_admin(
  db_role  VARCHAR
)
RETURNS VOID AS
$$
BEGIN
  EXECUTE '
  GRANT USAGE
     ON SCHEMA @extschema@
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.bootstrap_tier_parts(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.cap_tier_partitions()
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.extend_tier_root(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.get_tier_config(VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.initialize_tier_part(VARCHAR, VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.migrate_all_tiers()
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.migrate_tier_data(VARCHAR, VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.register_tier_root(VARCHAR, VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.set_tier_config(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.toggle_tier_partitions(VARCHAR, VARCHAR, BOOLEAN)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.unregister_table(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT SELECT
     ON TABLE @extschema@.tier_config
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT SELECT
     ON TABLE @extschema@.tier_root
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT SELECT
     ON TABLE @extschema@.tier_part
     TO ' || quote_ident(db_role);

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;

REVOKE EXECUTE
    ON FUNCTION add_tier_admin(VARCHAR)
  FROM PUBLIC;

/**
* Create all necessary partitions for a new tier root
*
* When selecting new tables to partition, registration is only the first step.
* The table is very likely to have existing data that needs to be relocated.
* The hardest part of relocating this old data is creating all of the
* tier partitions, which may number in the dozens. This library has functions
* to handle all this, so this function utilizes them to create partitions
* to accommodate the oldest data in the root table, to the edge of the
* retention window.
*
* @param string  Schema name of root table to bootstrap.
* @param string  Table Name of root table to bootstrap.
*/
CREATE OR REPLACE FUNCTION bootstrap_tier_parts(
  sSchema   VARCHAR,
  sTable    VARCHAR
)
RETURNS VOID AS $$
DECLARE
  rRoot @extschema@.tier_root%ROWTYPE;

  dStart DATE;
  dCurrent DATE;
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
  -- This will determine the date of our earliest partition.

  EXECUTE
    'SELECT min(' || quote_ident(rRoot.date_column) || ')
       FROM ' || quote_ident(sSchema) || '.' || quote_ident(sTable)
  INTO dStart;

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

  WHILE dCurrent < CURRENT_DATE - rRoot.root_retain + rRoot.part_period LOOP
    PERFORM @extschema@.extend_tier_root(sSchema, sTable);
    dCurrent = dCurrent + rRoot.part_period;
  END LOOP;

  -- Finally, delete the bootstrap row we created in the partition tracker.

  DELETE FROM @extschema@.tier_part
   WHERE tier_root_id = rRoot.tier_root_id
     AND part_table = 'strap';

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION bootstrap_tier_parts(VARCHAR, VARCHAR)
  FROM PUBLIC;


/**
* Ensures all root tables have at least one extra partition target 
*
* Because of the nature of the tier system, we want to ensure at least one
* target tier partition exists at all times for the desired date ranges.
* Doing otherwise requires a lot of extra manual work to do data shifting.
* This procedure checks all registered root tables in the tier system and
* will create new partitions to match the granularity in part_period.
*
* Calling this function several times in a row will do nothing on subsequent
* runs due to its design. It will only function when new partitions are needed.
*
* If any root can not be extended, it is skipped and a warning is raised.
*/
CREATE OR REPLACE FUNCTION cap_tier_partitions()
RETURNS VOID AS $$
DECLARE
  sSchema VARCHAR;
  sTable VARCHAR;
BEGIN

  -- This query should identify any root which is missing at least one
  -- partition for data older than root_retain. The gap between the current
  -- date and the most recent partition determines how many more partitions
  -- are generated. The minimum granularity for this function to work is
  -- 1 day.

  FOR sSchema, sTable IN SELECT r.root_schema, r.root_table,
             generate_series(1, floor(extract(epoch from (
                   coalesce(CURRENT_DATE - max(p.check_stop),
                   r.root_retain))) /
                   extract(epoch from r.root_retain))::int + 1) AS gap
        FROM @extschema@.tier_root r
        LEFT JOIN @extschema@.tier_part p USING (tier_root_id)
       GROUP BY r.root_schema, r.root_table, r.root_retain, r.part_period
      HAVING coalesce(CURRENT_DATE - max(p.check_stop), r.root_retain) >
             r.root_retain - r.part_period - INTERVAL '1 day'
  LOOP
    BEGIN
      PERFORM @extschema@.extend_tier_root(sSchema, sTable);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Problem encountered extending %! Skipping.', sTable;
      CONTINUE;
    END;
  END LOOP;

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION cap_tier_partitions()
  FROM PUBLIC;


/**
* Copy all object permissions from one table to another.
*
* When the tier system copies a table, the original owner is retained,
* but he may not be the only user. This function is provided to copy grants
* primarily for the partition system, but it can be used as a general grant
* copying system.
*
* This should be considered an internal function used only by the library.
*
* @param string  Name of Schema where source objects can be found.
* @param string  Name of the source table of permissions.
* @param string  Name of Schema where target objects can be found.
* @param string  Name of target table for copied permissions.
*/
CREATE OR REPLACE FUNCTION _copy_grants(
  sSchema     VARCHAR,
  sSource     VARCHAR,
  sNSPTarget  VARCHAR,
  sTarget     VARCHAR
)
RETURNS VOID AS $$
DECLARE
  rPerms RECORD;
BEGIN

  -- We'll have to requisition the information schema for this bit of info,
  -- as the EDB catalog is sufficiently complicated to dissuade direct
  -- inquiries.

  FOR rPerms IN SELECT grantee,
                       string_agg(privilege_type, ', ') AS perms
                  FROM information_schema.role_table_grants
                 WHERE table_schema = sSchema
                   AND table_name = sSource
                 GROUP BY grantee
  LOOP
    EXECUTE
      'GRANT ' || rPerms.perms || '
          ON ' || quote_ident(sNSPTarget) || '.' || quote_ident(sTarget) || '
          TO ' || rPerms.grantee;
  END LOOP;

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION _copy_grants(VARCHAR, VARCHAR, VARCHAR, VARCHAR)
  FROM PUBLIC;


/**
 * Remove a user or role who was allowed to use pg_tier.
 *
 * This is the functional analog to add_tier_admin. Calling this function
 * will remove a user or role from the list of those allowed to invoke tier
 * management routines. Functions permissions removed:
 *
 *  - bootstrap_tier_parts
 *  - cap_tier_partitions
 *  - extend_tier_root
 *  - get_tier_config
 *  - initialize_tier_part
 *  - migrate_all_tiers
 *  - migrate_tier_data
 *  - register_tier_root
 *  - set_tier_config
 *  - toggle_tier_partitions
 *  - unregister_table
 *
 * Table select permission removed:
 *
 *  - tier_config
 *  - tier_table
 *  - tier_map
 *
 * @param db_role  String user or role to remove as tier admin.
 */
CREATE OR REPLACE FUNCTION drop_tier_admin(
  db_role  VARCHAR
)
RETURNS VOID AS
$$
BEGIN
  EXECUTE '
  REVOKE USAGE
      ON SCHEMA @extschema@
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.bootstrap_tier_parts(VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.cap_tier_partitions()
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.extend_tier_root(VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.get_tier_config(VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.initialize_tier_part(VARCHAR, VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.migrate_all_tiers()
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.migrate_tier_data(VARCHAR, VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.register_tier_root(VARCHAR, VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.set_tier_config(VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.toggle_tier_partitions(VARCHAR, VARCHAR, BOOLEAN)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.unregister_table(VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE ALL
      ON TABLE @extschema@.tier_config
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE ALL
      ON TABLE @extschema@.tier_map
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE ALL
      ON TABLE @extschema@.tier_table
    FROM ' || quote_ident(db_role);

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;

REVOKE EXECUTE
    ON FUNCTION drop_tier_admin(VARCHAR)
  FROM PUBLIC;


/**
* Creates a new partition extension based on root table.
*
* This procedure will add one extent of part_period length to an existing
* registered root table. Each new partition will always be one period higher
* than the last registered partition. If none are found, the current date
* is used as a base.
* 
* All partition ranges are truncated down to no more than a day of granularity.
* In the case of granularity greater or equal to one month, ranges are cut
* down to start or stop on the first day of the months indicated.
*
* This function may be called in rapid succession by maintenance processes
* that are attempting to ensure migrated data always has a valid target.
*
* @param string  Schema name of root table being extended.
* @param string  Table Name of root table being extended.
*/
CREATE OR REPLACE FUNCTION extend_tier_root(
  sSchema   VARCHAR,
  sTable    VARCHAR
)
RETURNS VOID AS $$
DECLARE
  rRoot @extschema@.tier_root%ROWTYPE;

  dLast DATE;
  dStart DATE;
  sPartName VARCHAR;
  sIndex VARCHAR;
  sMask VARCHAR;
BEGIN

  -- Retrieve the root definition. We'll need that to define certain
  -- elements of the child partition we're creating.

  SELECT INTO rRoot *
    FROM @extschema@.tier_root
   WHERE root_schema = sSchema
     AND root_table = sTable;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not extend (%). Not found!', quote_ident(sTable);
  END IF;

  -- Given the root partition exists, try to find the most recent extension.
  -- The next extension should be named after that one, plus the partition
  -- interval. If not found, base it on the current date plus the root
  -- interval. Never go below day granularity, and if we're at a month or
  -- above, reset it to always fall on the first of each month in the range.
  -- This prevents embarrassing off-by-one errors and makes contents more
  -- predictable.

  SELECT INTO dLast check_stop
    FROM @extschema@.tier_part
   WHERE tier_root_id = rRoot.tier_root_id
   ORDER BY check_stop DESC
   LIMIT 1;

  dStart = coalesce(dLast, CURRENT_DATE - rRoot.root_retain);

  sMask = 'YYYYMMDD';
  IF rRoot.part_period >= INTERVAL '1 month' THEN
    sMask = 'YYYYMM';
    dStart = date_trunc('month', dStart);
  END IF;

  sPartName = sTable || '_part_' || to_char(dStart, sMask);

  -- Go ahead and create the table. It'll be based on the root table so we
  -- can copy indexes and table/column comments. We won't include any
  -- constraints, as those were presumably checked in the base table when
  -- the data was originally created. If this becomes a problem, they can
  -- be re-added. Otherwise, this is just a check-constraint table inheritance
  -- pattern on our root interval.

  EXECUTE '
    CREATE TABLE ' || quote_ident(sSchema) || '.' || quote_ident(sPartName) || '
    (
      snapshot_dt TIMESTAMP WITHOUT TIME ZONE NOT NULL,
      CHECK (' || quote_ident(rRoot.date_column) || ' >= ' ||
                  quote_literal(dStart::text) || '
        AND ' || quote_ident(rRoot.date_column) || ' < ' ||
                 quote_literal((dStart + rRoot.part_period)::text) || '),
      LIKE ' || quote_ident(sSchema) || '.' || quote_ident(sTable) || '
      INCLUDING INDEXES INCLUDING COMMENTS
    ) INHERITS (' || quote_ident(sSchema) || '.' || quote_ident(sTable) || ')
    TABLESPACE ' || rRoot.part_tablespace;

  -- Next, we should move the indexes to the proper tablespace as well, as
  -- that's one thing that doesn't get inherited.

  FOR sIndex IN
      SELECT indexname
        FROM pg_indexes
       WHERE schemaname = sSchema
         AND tablename = sPartName
  LOOP
    EXECUTE
      'ALTER INDEX ' || quote_ident(sSchema) || '.' || quote_ident(sIndex) ||
      '  SET TABLESPACE ' || quote_ident(rRoot.part_tablespace);
  END LOOP;

  -- Last but not least, copy the grants of our parent table.

  PERFORM @extschema@._copy_grants(sSchema, sTable, sSchema, sPartName);

  -- Now that we've created the partition, go ahead and record everything
  -- for posterity in our tracking table.

  INSERT INTO @extschema@.tier_part (tier_root_id, part_schema, part_table,
          check_start, check_stop)
  VALUES (rRoot.tier_root_id, sSchema, sPartName, dStart,
          dStart + rRoot.part_period);

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION extend_tier_root(VARCHAR, VARCHAR)
  FROM PUBLIC;


/**
 * Retrieve a Configuration Setting from tier_config.
 *
 * @param config_key  Name of the configuration setting to retrieve.
 *
 * @return TEXT  Value for the requested configuration setting.
 */
CREATE OR REPLACE FUNCTION get_tier_config(
  config_key  VARCHAR
)
RETURNS TEXT AS
$$
BEGIN
  RETURN (SELECT setting
    FROM @extschema@.tier_config
   WHERE config_name = config_key);
END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;

REVOKE EXECUTE
    ON FUNCTION get_tier_config(VARCHAR)
  FROM PUBLIC;


/**
* Copy all data from root for named partition in fastest way possible
*
* When partitions are created, they are empty. This function will copy data
* from the root table to the specified partition just like
* migrate_tier_data. However, it disables indexes before invoking the
* data movement and then reenables them, which is much faster when inserting
* large amounts of data.
*
* @param string  Schema name of root table owning partition to initialize.
* @param string  Table Name of root table owning partition table to initialize.
* @param string  Specific partition to target, root table and partition
*                prefix removed. Ex: 201304
*/
CREATE OR REPLACE FUNCTION initialize_tier_part(
  sSchema   VARCHAR,
  sTable    VARCHAR,
  sPart     VARCHAR
)
RETURNS VOID AS $$
DECLARE
  oTarget REGCLASS;
BEGIN

  -- Data sanitize the supplied partition and turn it into a table name.

  SELECT INTO oTarget (part_schema || '.' || part_table)::regclass
    FROM @extschema@.tier_part
   WHERE part_table = sTable || '_part_' || 
                      regexp_replace(sPart, '\D', '', 'g');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not initialize %. Partition missing.',
          quote_ident(oTarget::text);
  END IF;

  -- To do this as quickly as possible, we need to disable all indexes on the
  -- target partition. We will reenable this later.

  UPDATE pg_index
     SET indisready = FALSE,
         indisvalid = FALSE
   WHERE indrelid = oTarget;

  -- Call the migration function which does all the actual heavy lifting.

  RAISE NOTICE 'Initializing partition %.', oTarget::text;

  PERFORM @extschema@.migrate_tier_data(sSchema, sTable, sPart);

  -- Reenable the indexes and inheritance we disabled earlier, and force a
  -- reindex of the table. This will take a while, but potentially inserting
  -- several million rows with them enabled would have been much worse.

  UPDATE pg_index
     SET indisready = TRUE,
         indisvalid = TRUE
   WHERE indrelid = oTarget;

  RAISE NOTICE ' * Rebuilding partition indexes.';

  EXECUTE
    'REINDEX TABLE ' || oTarget::text;

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION initialize_tier_part(VARCHAR, VARCHAR, VARCHAR)
  FROM PUBLIC;


/**
* Migrate data in all registered tier root tables at once.
*
* Several tables are probably registered with the tier system already.
* These tables should regularly have data moved into the low-priority
* tier. This routine will ensure all old root data exists in the proper
* tier partitions for the entirety of their retention window by calling
* the update process for every known tier root.
*
* In cases where a procedure (tier_proc) is defined, it will call that
* instead of the generic (migrate_tier_data) procedure designed to
* handle simple partition schemes.
*/
CREATE OR REPLACE FUNCTION migrate_all_tiers()
RETURNS VOID AS $$
DECLARE
  rPart @extschema@.tier_root%ROWTYPE;
BEGIN

  -- Simply loop through all known root tables.
  -- In all cases, call the appropriate (date-based or user-defined) procedure
  -- that migrates data from the root table(s) to the target partition.

  FOR rPart IN SELECT * FROM @extschema@.tier_root
  LOOP
    BEGIN
      IF rPart.tier_proc IS NULL THEN
        PERFORM @extschema@.migrate_tier_data(rPart.root_schema,
          rPart.root_table);
      ELSE
        EXECUTE 'SELECT @extschema@.' || rPart.tier_proc || '()';
      END IF;

    -- If one tier barfs, there's no reason *all* of them should.

    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Problem encountered with %! Skipping.', rPart.root_table;
      CONTINUE;
    END;

  END LOOP;

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION migrate_all_tiers()
  FROM PUBLIC;


/**
* Move data from root table to current tier partition
*
* Given a root table we've already registered and at least one active
* partition, it should be possible to move data older than root_retain
* to a partition where the data being archived falls within that partition.
* Other stored procedures exist to make sure there's always at least one
* of these, but the worst that can happen in the case of a missing partition
* is that data doesn't get relocated to the slower device.
*
* This procedure always proceeds in a copy -> delete order to ensure data
* is safe in the partition before being removed from the root. Any query that
* targets the root will also retrieve all partitions, so availability should
* not change unless the ONLY keyword is specified.
*
* @param string  Schema name of root table having data migrated.
* @param string  Table Name of root table having data migrated.
* @param string  Optional specific partition to target, root table and
*                partition prefix removed. Ex: 201304
*/
CREATE OR REPLACE FUNCTION migrate_tier_data(
  sSchema   VARCHAR,
  sTable    VARCHAR,
  sPart     VARCHAR DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
  rRoot @extschema@.tier_root%ROWTYPE;
  rPart @extschema@.tier_part%ROWTYPE;

  sColList VARCHAR;
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
       AND check_stop > CURRENT_DATE - rRoot.root_retain
     ORDER BY check_stop DESC
     LIMIT 1;
  ELSE
    SELECT INTO rPart *
      FROM @extschema@.tier_part
     WHERE tier_root_id = rRoot.tier_root_id
       AND part_table = sTable || '_part_' || 
                        regexp_replace(sPart, '\D', '', 'g');
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

  EXECUTE
    'INSERT INTO ' || quote_ident(rPart.part_schema) || '.' ||
                      quote_ident(rPart.part_table) || 
            ' ( ' || sColList || ', snapshot_dt)
     SELECT ' || sColList || ', now()
       FROM ONLY ' || quote_ident(sSchema) || '.' || quote_ident(sTable) || '
      WHERE ' || quote_ident(rRoot.date_column) || ' >= ' ||
                 quote_literal(rPart.check_start::text) || '
        AND ' || quote_ident(rRoot.date_column) || ' < ' ||
                 quote_literal(rPart.check_stop::text) || '
        AND ' || quote_ident(rRoot.date_column) || ' < CURRENT_DATE - ' ||
                 quote_literal(rRoot.root_retain::text) || '::interval';

  -- Once the rows are copied, it should be safe to delete them from the
  -- source. Since all children inherit from the main table, we want to
  -- *ensure* to use the ONLY keyword so we don't delete from all of the
  -- other partitions as well.

  RAISE NOTICE ' * Deleting data from old tier.';

  EXECUTE
    'DELETE FROM
       ONLY ' || quote_ident(sSchema) || '.' || quote_ident(sTable) || '
      WHERE ' || quote_ident(rRoot.date_column) || ' >= ' ||
                 quote_literal(rPart.check_start::text) || '
        AND ' || quote_ident(rRoot.date_column) || ' < ' ||
                 quote_literal(rPart.check_stop::text) || '
        AND ' || quote_ident(rRoot.date_column) || ' < CURRENT_DATE - ' ||
                 quote_literal(rRoot.root_retain::text) || '::interval';

  -- Last but not least, analyze our source table because we probably
  -- invalidated the last collected statistics.

  RAISE NOTICE ' * Updating statistics.';

  EXECUTE 'ANALYZE ' || quote_ident(sSchema) || '.' || quote_ident(sTable);
  EXECUTE 'ANALYZE ' || quote_ident(rPart.part_schema) || '.' || 
          quote_ident(rPart.part_table);

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION migrate_tier_data(VARCHAR, VARCHAR, VARCHAR)
  FROM PUBLIC;


/**
* Registers a table with the tier management system
*
* This procedure registers a table with the tier management system in such
* a way that only the non-default columns are specified. To override a default,
* alter the table entry in tier_root. 
*
* @param string  Name of Schema where root resides.
* @param string  Name of the table to register.
* @param string  Date-based column to use as partition pivot.
*/
CREATE OR REPLACE FUNCTION register_tier_root(
  sSchema   VARCHAR,
  sTable    VARCHAR,
  sColumn   VARCHAR
)
RETURNS VOID AS $$
DECLARE
  dRetain   INTERVAL;
  dPeriod   INTERVAL;
  dThresh   INTERVAL;
  sStorage  TEXT;
BEGIN

  dRetain = @extschema@.get_tier_config('root_retain');
  dPeriod = @extschema@.get_tier_config('part_period');
  dThresh = @extschema@.get_tier_config('lts_threshold');
  sStorage = @extschema@.get_tier_config('part_tablespace');

  -- Check for this schema/table/column combination, to save us from having to
  -- trap an exception.

  PERFORM 1
     FROM @extschema@.tier_root
    WHERE root_schema = sSchema
      AND root_table = sTable;

  IF NOT FOUND THEN
    INSERT INTO @extschema@.tier_root (root_schema, root_table, date_column,
                part_tablespace, root_retain, part_period, lts_threshold)
    VALUES (sSchema, sTable, sColumn, sStorage, dRetain, dPeriod, dThresh);
  END IF;

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION register_tier_root(VARCHAR, VARCHAR, VARCHAR)
  FROM PUBLIC;


/**
 * Set a Configuration Setting from pg_tier.
 *
 * This function doesn't just set values. It also acts as an API for
 * checking setting validity. These settings are specifically adjusted:
 *
 *  - root_retain : Must be able to convert to a PostgreSQL INTERVAL type.
 *  - lts_threshold : Must be able to convert to a PostgreSQL INTERVAL type.
 *  - part_period : Must be able to convert to a PostgreSQL INTERVAL type.
 *
 * All settings will be folded to lower case for consistency.
 *
 * @param config_key  Name of the configuration setting to retrieve.
 * @param config_val  full value to use for the specified setting.
 *
 * @return TEXT  Value for the created/modified configuration setting.
 */
CREATE OR REPLACE FUNCTION set_tier_config(
  config_key  VARCHAR,
  config_val  VARCHAR
)
RETURNS TEXT AS
$$
DECLARE
  new_val   VARCHAR := config_val;
  low_key   VARCHAR := lower(config_key);
  info_msg  VARCHAR;
BEGIN
  -- If this is a new setting we don't control, just set it and ignore it.
  -- The admin may be storing personal notes. Any settings required by the
  -- extension should already exist by this point.

  PERFORM 1 FROM @extschema@.tier_config WHERE config_name = low_key;

  IF NOT FOUND THEN
    INSERT INTO @extschema@.tier_config (config_name, setting)
    VALUES (low_key, new_val);

    RETURN new_val;
  END IF;

  -- Don't let the user choose a tablespace that doesn't exist.

  IF low_key = 'part_tablespace' THEN
    PERFORM 1 FROM pg_tablespace WHERE spcname = config_val;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% is not a valid tablespace!', config_val;
      RETURN NULL;
    END IF;
  END IF;

  -- Make sure all of the INTERVAL types are actually intervals.

  IF low_key IN ('root_retain', 'lts_threshold', 'part_period') THEN
    BEGIN
      SELECT config_val::INTERVAL;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE EXCEPTION '% is not an interval!', config_val;
        RETURN NULL;
    END;
  END IF;

  -- With the data filtered, it's now safe to modify the config table.
  -- Also set the default to false so non-default settings are retained
  -- in dumps.

  UPDATE @extschema@.tier_config
     SET setting = new_val,
         is_default = False
   WHERE config_name = low_key;

  -- Finally, return the value of the setting, indicating it was accepted.

  RETURN new_val;

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;

REVOKE EXECUTE
    ON FUNCTION set_tier_config(VARCHAR, VARCHAR)
  FROM PUBLIC;


/**
* Detaches or Attaches all partitions from named tier root
*
* When root tiers are first bootstrapped, the new partitions are all empty
* yet moving data into them will cause locking issues should the partition
* itself undergo index manipulation. Since this is done by certain helper
* functions to speed initial data population, it's best to detach our new
* partitions. Otherwise, the parent table would be effectively unusable
* during the data migration.
*
* In turn, it makes sense to later enable these same partitions when they're
* safely full of data. We initially built this functionality into the 
* initialization function, but since functions get their own transaction
* context, detached tables were still attached in the context of any other
* transaction that started before we committed, making the action effectively
* worthless. This procedure is supplied as a workaround so the detachment
* and attachment processes get their own transaction context.
*
* @param string   Schema name of root table to toggle partitions.
* @param string   Table Name of root table to toggle partitions.
* @param boolean  TRUE to enable partitions, FALSE to disable.
*/
CREATE OR REPLACE FUNCTION toggle_tier_partitions(
  sSchema   VARCHAR,
  sTable    VARCHAR,
  bEnabled  BOOLEAN
)
RETURNS VOID AS $$
DECLARE
  sPartName VARCHAR;
BEGIN

  -- Just loop through all known partitions for the supplied root table.
  -- Enable or disable based on the passed boolean flag.

  FOR sPartName IN SELECT p.part_schema || '.' || p.part_table
        FROM @extschema@.tier_root r
        JOIN @extschema@.tier_part p USING (tier_root_id)
       WHERE r.root_schema = sSchema
         AND r.root_table = sTable
  LOOP
    BEGIN
      EXECUTE 
        'ALTER TABLE ' || sPartName || 
                       CASE WHEN bEnabled THEN '' ELSE ' NO' END || '
               INHERIT ' || quote_ident(sSchema) || '.' || quote_ident(stable);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Problem encountered detaching %! Skipping.', sPartName;
      CONTINUE;
    END;
  END LOOP;

END;
$$ LANGUAGE plpgsql VOLATILE;

REVOKE EXECUTE
    ON FUNCTION toggle_tier_partitions(VARCHAR, VARCHAR, BOOLEAN)
  FROM PUBLIC;


/**
 * Remove a table/schema pair from the pg_tier system.
 *
 * This function simplifies removing tables from pg_tier. Tables removed
 * with this function will no longer have data moved by any functions
 * used by this extension. Otherwise, no modifications will be made to
 * the tables themselves.
 *
 * @param table_schema  String name of the schema for this table.
 * @param target_table  String name of the *base* table to remove from pg_tier;
 *     all child tables will also be unregistered.
 */
CREATE OR REPLACE FUNCTION unregister_table(
  table_schema  VARCHAR,
  target_table  VARCHAR
)
RETURNS VOID AS
$$
BEGIN

  DELETE FROM @extschema@.tier_root
   WHERE root_schema = table_schema
     AND root_table = target_table;

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;

REVOKE EXECUTE
    ON FUNCTION unregister_table(VARCHAR, VARCHAR)
  FROM PUBLIC;


/**
* Update created/modified timestamp automatically
*
* This function maintains two metadata columns on any table that uses
* it in a trigger. These columns include:
*
*  - created_dt  : Set to when the row first enters the table.
*  - modified_at : Set to when the row is ever changed in the table.
*
* @return object  NEW 
*/
CREATE OR REPLACE FUNCTION update_audit_stamps()
RETURNS TRIGGER AS
$$
BEGIN

  -- All inserts get a new timestamp to mark their creation. Any updates should
  -- inherit the timestamp of the old version. In either case, a modified
  -- timestamp is applied to track the last time the row was changed.

  IF TG_OP = 'INSERT' THEN
    NEW.created_dt = now();
  ELSE
    NEW.created_dt = OLD.created_dt;
  END IF;

  NEW.modified_dt = now();

  RETURN NEW;

END;
$$ LANGUAGE plpgsql;

REVOKE EXECUTE
    ON FUNCTION update_audit_stamps()
  FROM PUBLIC;

--------------------------------------------------------------------------------
-- CREATE TRIGGERS
--------------------------------------------------------------------------------

CREATE TRIGGER t_tier_config_timestamp_b_iu
BEFORE INSERT OR UPDATE ON tier_config
   FOR EACH ROW EXECUTE PROCEDURE update_audit_stamps();

CREATE TRIGGER t_tier_root_timestamp_b_iu
BEFORE INSERT OR UPDATE ON tier_root
   FOR EACH ROW EXECUTE PROCEDURE update_audit_stamps();

CREATE TRIGGER t_tier_part_timestamp_b_iu
BEFORE INSERT OR UPDATE ON tier_part
   FOR EACH ROW EXECUTE PROCEDURE update_audit_stamps();

--------------------------------------------------------------------------------
-- CONFIGURE EXTENSION
--------------------------------------------------------------------------------

INSERT INTO tier_config (config_name, setting, is_default) VALUES
  ('root_retain', '3 Months', True),
--  ('lts_threshold', '2 years', True),
  ('part_period', '1 Month', True),
  ('part_tablespace', 'pg_default', TRUE);
