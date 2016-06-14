tab_tier Extension
=======================

The tab_tier module is an extension aimed at promoting simpler table partitioning.

The PostgreSQL documentation and existing modules suggest using triggers to redirect inserts from a base table to various child tables. In this style, the base table is empty and all of the child tables actually contain data as defined by `CHECK` constraints. The [pg_partman](http://pgxn.org/dist/pg_partman/doc/pg_partman.html) extension for example, automates managing such a structure.

This approach can impart too much overhead for OLTP databases, both to maintain the triggers themselves, and in executing the trigger logic itself. Further, the base table can not be used for actual data retrieval when addressed with the `ONLY` keyword since it is empty.

This extension advocates a simplified process. Any table managed by this extension is defined with an initial retention period, and a partition interval. The primary maintenance function simply relocates data older than the retention period from the base table to the appropriate child table. Combined with the `ONLY` keyword, basic application usage can focus on recent data without knowing the partition scheme itself, or even using a targeted WHERE clause.

In addition, we've provided functions to break existing tables into a partitioned family to avoid error-prone manual deployment.

Installation
============

To use tab_tier, it must first be installed. Simply execute this commands in the database that needs tier-based functionality:

    CREATE EXTENSION tab_tier;

This extension does not need to reside in the default tab_tier schema. To install it elsewhere, use these commands instead:

    CREATE SCHEMA my_schema;
    CREATE EXTENSION tab_tier SCHEMA my_schema;

Usage
=====

The tab_tier extension works by maintaining a root table and all children based on some very simple constraints. Let's make a basic schema and fake data now:

    CREATE SCHEMA comm;

    CREATE TABLE comm.yell (
      id          SERIAL PRIMARY KEY NOT NULL,
      message     TEXT NOT NULL,
      created_dt  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
    );

    INSERT INTO comm.yell (message, created_dt)
    SELECT 'I have ' || id || ' cows!',
           now() - (id || 'd')::INTERVAL
      FROM generate_series(1, 1000) a (id);

That was easy! To use tab_tier, there are five basic steps:

1. Registration
2. Bootstrapping
3. Migration
4. Archival
5. Maintenance

Only the last three of these will be repeated on a regular basis.

### Registration

The registration step basically enters the table into the `tier_config` configuration table after applying a few basic sanity checks and defaults. Let's register the `comm.yell` table, then check the `tier_root` table's contents:

    SELECT tab_tier.register_tier_root('comm', 'yell', 'created_dt');
    SELECT * FROM tab_tier.tier_root;

The output from the select gives us a lot of information we didn't specify:

    -[ RECORD 1 ]---+---------------------------
    tier_root_id    | 1
    root_schema     | comm
    root_table      | yell
    date_column     | created_dt
    part_period     | 1 mon
    tier_proc       | 
    part_tablespace | pg_default
    root_retain     | 3 mons
    lts_target      | 
    lts_threshold   | 
    is_default      | f
    created_dt      | 2015-02-20 15:42:20.267042
    modified_dt     | 2015-02-20 15:42:20.267042

Many of these fields will be explained later, and it's fairly clear the registration was successful.

### Bootstrapping

Next, we need to actually partition the sample table. Effectively, tab_tier will examine the `created_dt` column in `comm.yell` and figure out the minimum and maximum dates. Using the one-month partition period, and three-month retention interval, it will force-distribute any existing data. Any child tables will also have appropriate check constraints added to satisfy PostgreSQL's constraint exclusion performance tweak.

This function call should do the trick:

    SELECT tab_tier.bootstrap_tier_parts('comm', 'yell');

And we can check for the new partitions by checking `tier_part`:

    SELECT part_table, check_start, check_stop
      FROM tab_tier.tier_part
     ORDER BY part_table
     LIMIT 10;

We used a limit because the sample data we used constitutes almost three years of data, and monthly partitions would mean around thirty partitions.

        part_table    |     check_start     |     check_stop      
    ------------------+---------------------+---------------------
     yell_part_201205 | 2012-05-01 00:00:00 | 2012-06-01 00:00:00
     yell_part_201206 | 2012-06-01 00:00:00 | 2012-07-01 00:00:00
     yell_part_201207 | 2012-07-01 00:00:00 | 2012-08-01 00:00:00
     yell_part_201208 | 2012-08-01 00:00:00 | 2012-09-01 00:00:00
     yell_part_201209 | 2012-09-01 00:00:00 | 2012-10-01 00:00:00
     yell_part_201210 | 2012-10-01 00:00:00 | 2012-11-01 00:00:00
     yell_part_201211 | 2012-11-01 00:00:00 | 2012-12-01 00:00:00
     yell_part_201212 | 2012-12-01 00:00:00 | 2013-01-01 00:00:00
     yell_part_201301 | 2013-01-01 00:00:00 | 2013-02-01 00:00:00
     yell_part_201302 | 2013-02-01 00:00:00 | 2013-03-01 00:00:00

There are clearly more partitions than listed above.

Some use cases include the possibility that events or data points will be dated in the future. To accommodate these scenarios, the `bootstrap_tier_parts` function has one last parameter that, if true, tells it to create partitions even for future dates. Normally, partitions end one retention interval before the current date.

### Migration

Once the partitions exist, we need to move the data. The tab_tier extension does not provide a function that does this all in one step, because a table being partitioned is likely very large. Waiting for the process to complete may take several hours (or even days) and any error can derail the process.

However, we do provide a function to handle the data for each individual partition. Let's move the data in the January 2013 partition. How do we know the partition name? If `part_period` is less than a month, all partition names come in YYYYMMDD format, otherwise they are named with YYYYMM. So in this case, we will use '201301':

    SELECT tab_tier.migrate_tier_data('comm', 'yell', '201301');

    NOTICE:  Migrating Older yell Data
    NOTICE:   * Copying data to new tier.
    NOTICE:   * Deleting data from old tier.
    NOTICE:   * Updating statistics.

Then we should check that the data was actually moved:

    SELECT count(1) FROM comm.yell_part_201301;

     count 
    -------
        31

    SELECT count(1) FROM ONLY comm.yell;

     count 
    -------
       969

As we can see, 31 rows were moved from the root table to the appropriate partition. Doing this for several partitions could be annoying though, so we suggest creating a script like this:

    COPY (
      SELECT 'SELECT tab_tier.migrate_tier_data(''comm'', ''yell'', ''' || 
             replace(part_table, 'yell_part_', '') || ''');' AS part_name
        FROM tab_tier.tier_part
        JOIN tab_tier.tier_root USING (tier_root_id)
       WHERE root_schema = 'comm'
         AND root_table = 'yell'
       ORDER BY part_table
    ) TO '/tmp/move_parts.sql';

Then, execute the resulting script with `psql` or pgAdmin. This way if the process gets interrupted or might take too long, it can be performed in sections or easily resumed. If this is not an overly problematic concern, feel free to substitute the `flush_tier_data` function discussed below; it performs the same data redistribution as a single transactional operation.

### Maintenance

Finally, there's partition maintenance. Primarily this will include functions that ensure partition targets exist, and perform data movement on all registered root tables.

Any registered root table will need to have a target partition for relocated data. The tier system does keep track of any partitions that exist, so it won't move data where the target is missing, but that just means the root table slowly grows larger than intended.

This means the `cap_tier_partitions` function should be called regularly. It walks through any tables registered in `tier_root` and creates any missing partitions between the current date and the `root_retain` setting for the table. Simply schedule it to be invoked more often than the `part_period` setting, and a partition will always be available for data. We recommend just calling it every night as part of basic maintenance.

Afterwards comes actually moving the data. The easiest way to do this is to regularly execute the `migrate_all_tiers` function. Like `cap_tier_partitions`, it reads all of the root tables in `root_retain` and uses that to move data from every root table to the most recent partition. The assumption here is that the function is called more often than `part_period` so only the most recent partition is relevant. It also presents status information while working:

    SELECT migrate_all_tiers();
    
    NOTICE:   * Copying data to new tier.
    NOTICE:   * Deleting data from old tier.
    NOTICE:   * Updating statistics.

If this is ever not the case, we also provide a function for manually moving data, simply rely on the `migrate_tier_data` function as discussed previously.

In some cases, a DBA will need to perform more intrusive maintenance. Due to the way partitions are used in PostgreSQL, object-locking can be an issue since many tables are locked simultaneously when the root table is used in a query. Fortunately there's an easy way to handle this. The `toggle_tier_partitions` function will attach or detach child partitions from a specified root table.

Let's see a few partitions first:

    SELECT c.relname AS child_name
      FROM pg_class c
      JOIN pg_inherits i ON (i.inhrelid = c.oid)
     WHERE i.inhparent = 'comm.yell'::REGCLASS
     LIMIT 5;

        child_name    
    ------------------
     yell_part_201205
     yell_part_201206
     yell_part_201207
     yell_part_201208
     yell_part_201209
    (5 rows)

Next, decouple the tables by sending **FALSE**:

    SELECT tab_tier.toggle_tier_partitions('comm', 'yell', FALSE);

    SELECT c.relname AS child_name
      FROM pg_class c
      JOIN pg_inherits i ON (i.inhrelid = c.oid)
     WHERE i.inhparent = 'comm.yell'::REGCLASS
     LIMIT 5;

     child_name 
    ------------
    (0 rows)

This makes it easier to make table alterations to the root table without disturbing child partitions.

### Archival

This is where the "tier" part of tab_tier comes in. Data that has surpassed `lts_threshold` in age can be relocated to longer-term storage that either resides locally, or on a remote system accessed via foreign tables named by `lts_target`. Once archived, old partitions should dropped by calling `drop_archived_tiers`. Like most partition systems, the primary benefit of this approach is that we avoid long `DELETE` times, and is especially useful for extremely large tables.

Because not all systems require long term storage, this mechanism is entirely optional. To invoke it for our `comm.yell` table, simply call this function:

    SELECT tab_tier.archive_tier('comm', 'yell');

    NOTICE:  Migrating Older yell Data to LTS
    NOTICE:   * Archiving yell_part_201510
    NOTICE:     - Moving data to LTS
    NOTICE:     - Dropping archived partition
    ...

There's also a related maintenance function to archive any applicable partition related to any table registered to tab_tier. It works in a very similar manner to `migrate_all_tiers`:

    SELECT tab_tier.archive_all_tiers();

    NOTICE:  Migrating Older yell Data to LTS
    NOTICE:   * Archiving yell_part_201510
    NOTICE:     - Moving data to LTS
    NOTICE:     - Dropping archived partition
    ...

These functions are written such that any past archival failures will not prevent future data movement. Once any issues are resolved, all partitions beyond `lts_threshold` are candidates for archival.

### Flushing

If the partition maintenance functions were not called over a large period of time, it's possible unwanted data will remain in the root table. This is because the default migration system only targets the most recent partition as an optimization step. In these cases, it may be beneficial to force tab_tier to process all rows in a root table, for all existing partitions. The `flush_tier_data` function was provided for this task. Like `migrate_tier_data`, simply specify which root schema and table to target, and tab_tier will attempt to flush all rows from the root table into applicable partitions.

Because this function migrates *all* data from the root table, if called immediately following `bootstrap_tier_parts`, it will relocate data to all new partitions as a single monumental transaction. We strongly recommend against using this function for that purpose on extremely large tables, as the full migration will likely require hours, and any error will purge all previous progress.

Similarly, there is an analogous function that will invoke this process for all root tables. The `flush_all_tiers` function exists to save time and invocation complexity, calling `flush_tier_data` on all registered root tables. Again, ideally this should be considered a maintenance or clean up function, not a reorganization step following a registration bootstrap.


Configuration
=============

Configuring tab_tier has been simplified by the introduction of two functions designed to handle setting validation and other internals. To see all settings at once, execute this query to examine the contents of the `tier_config` table.

    SELECT config_name, setting FROM tab_tier.tier_config;

There are only a few settings currently that can be modified:

       config_name   |  setting   
    -----------------+------------
     root_retain     | 3 Months
     lts_threshold   | 2 years
     part_period     | 1 Month
     part_tablespace | pg_default

In this case, each partition will contain one month of data, the root table will contain three months before data is moved during maintenance, and data will be retained in partitions for two years before being ushered into long term storage.

To change settings, use the `set_tier_config` function as seen here:

    SELECT tab_tier.set_tier_config('root_retain', '6 Months');

Note that this function *does* check the validity of the setting in question. Here's what would happen if we passed a string that does not represent an interval:

    SELECT tab_tier.set_tier_config('root_retain', 'cow');

    ERROR:  cow is not an interval!

Here's a map of all currently recognized configuration settings:

Setting | Description
--- | ---
root_retain | A PostgreSQL INTERVAL of how long in days to keep data in the root table before moving it to one of the child partitions. Smallest granularity is one day. Default: 3 months.
part_period | A PostgreSQL INTERVAL dictating the period of time each partition should represent. The smallest granularity is one day. Default: 1 month.
lts_threshold | A PostgreSQL INTERVAL outlining how long data should reside within tier partitions before being moved to long term storage. Default: 2 years.
part_tablespace | Which tablespace should new partitions inhabit? This is in the case tab_tier is used as a pseudo-archival system where a slower tier of storage is used for older partitioned data. Default: pg_default.

While these settings are globally defined for the extension, they can also be changed on an individual basis by setting the corresponding columns in the `tier_root` table for each registered root table. There are also some settings that apply only to `tier_root` and are listed below:

Setting | Description
--- | ---
tier_proc | This function will be called instead of `migrate_tier_data` when `migrate_all_tiers` is used. Since the function is specific to a root table, it does not accept parameters. This may change in the future to accommodate generic user-defined migration functions.
lts_target | Must be set for `archive_tier` to work. This should either be a local table, or a foreign table located in a long term storage archival instance. Archived data will be moved to this location when `archive_tier` is called. Please see documentation on [creating foreign tables](http://www.postgresql.org/docs/current/static/sql-createforeigntable.html) for more information.


Tables
======

The tab_tier extension has a few tables that provide information about its operation and configuration. These tables include:

Setting | Description
--- | ---
tier_config | Contains all global settings for the module. Modify these with the  `set_tier_config` function.
tier_root | A table that tracks all registered root tables that should be managed by tab_tier. Partitions will be based on entries here, and configuration overrides can also be changed in this table.
tier_part | Lists each known partition and its parent root table. Also included are the beginning and ending constraints used to help the PostgreSQL query planner. This information makes it easy to determine the boundaries of each partition without examining each individually.


Security
========

Due to its low-level operation, tab_tier works best when executed by a database superuser. However, we understand this is undesirable in many cases. Certain tab_tier capabilities can be assigned to other users by granting access to `tab_tier_role`. For example:

    GRANT tab_tier_role TO some_user;

As with all grants, access can be removed via `REVOKE`.


Build Instructions
==================

To build it, just do this:

    cd tab_tier
    make
    sudo make install

If you encounter an error such as:

    make: pg_config: Command not found

Be sure that you have `pg_config` installed and in your path. If you used a
package management system such as RPM to install PostgreSQL, be sure that the
`-devel` package is also installed. If necessary tell the build process where
to find it:

    export PG_CONFIG=/path/to/pg_config
    make
    sudo make install

And finally, if all that fails (and if you're on PostgreSQL 8.1 or lower, it
likely will), copy the entire distribution directory to the `contrib/`
subdirectory of the PostgreSQL source tree and try it there without
`pg_config`:

    export NO_PGXS=1
    make
    make install


Dependencies
============

The `tab_tier` extension has no dependencies other than PostgreSQL.


Compatibility
=============

This extension should work with Postgres 9.1 and above. If this is not the case, please inform us so we can make necessary corrections.


Copyright and License
=====================

Copyright (c) 2014 Peak6

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
