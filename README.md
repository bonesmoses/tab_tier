pg_tier Extension
=======================

The pg_tier module is an extension aimed at promoting simpler table partitioning.

The PostgreSQL documentation and existing modules suggest using triggers to redirect inserts from a base table to various child tables. In this style, the base table is empty and all of the child tables actually contain data as defined by `CHECK` constraints. The [pg_partman](http://pgxn.org/dist/pg_partman/doc/pg_partman.html) extension for example, automates managing such a structure.

This approach can impart too much overhead for OLTP databases, both to maintain the triggers themselves, and in executing the trigger logic itself. Further, the base table can not be used for actual data retrieval when addressed with the `ONLY` keyword since it is empty.

This extension advocates a simplified process. Any table managed by this extension is defined with an initial retention period, and a partition interval. The primary maintenance function simply relocates data older than the retention period from the base table to the appropriate child table. Combined with the `ONLY` keyword, basic application usage can focus on recent data without knowing the partition scheme itself, or even using a targeted WHERE clause.

In addition, we've provided functions to break existing tables into a partitioned family to avoid error-prone manual deployment.

Installation
============

To use pg_tier, it must first be installed. Simply execute these commands in the database that needs tier-based functionality:

    CREATE SCHEMA tier;
    CREATE EXTENSION pg_tier WITH SCHEMA tier;

The `tier` schema isn't strictly necessary, but we recommend keeping namespaces isolated.


Usage
=====

The pg_tier extension works by maintaining a base table and all children based on some very simple constraints. Let's make a very basic schema and fake data now:

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

That was easy! To use pg_tier, there are four basic steps:

* Registration
* Bootstrapping
* Migration
* Maintenance

### Registration

The registration step basically enters the table into the `tier_config` configuration table after applying a few basic sanity checks and defaults. Let's register the `comm.yell` table, then check the `tier_root` table's contents:

    SELECT tier.register_tier_root('comm', 'yell', 'created_dt');
    SELECT * FROM tier.tier_root;

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

Next, we need to actually partition the sample table. Effectively, pg_tier will examine the `created_dt` column in `comm.yell` and figure out the minimum and maximum dates. Using the one-month partition period, and three-month retention interval, it will force-distribute any existing data. Any child tables will also have appropriate check constraints added to satisfy PostgreSQL's constraint exclusion performance tweak.

This function call should do the trick:

    SELECT tier.bootstrap_tier_parts('comm', 'yell');

And we can check for the new partitions by checking `tier_part`:

    SELECT part_table, check_start, check_stop
      FROM tier.tier_part
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

### Migration

Once the partitions exist, we need to move the data. The pg_tier extension does not provide a function that does this all in one step, because a table being partitioned is likely very large. Waiting for the process to complete may take several hours and any error can derail the process.

However, we do provide a function to handle the data for each individual partition. Let's move the data in the `201301` partition:

    SELECT tier.migrate_tier_data('comm', 'yell', '201301');

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
      SELECT 'SELECT tier.migrate_tier_data(''comm'', ''yell'', ''' || 
             replace(part_table, 'yell_part_', '') || ''');' AS part_name
        FROM tier.tier_part
        JOIN tier.tier_root USING (tier_root_id)
       WHERE root_schema = 'comm'
         AND root_table = 'yell'
       ORDER BY part_table
    ) TO '/tmp/move_parts.sql';

Then, execute the resulting script with `psql` or pgAdmin. This way if the process gets interrupted or might take too long, it can be performed in sections or easily resumed. If there is enough demand, we may provide a method of automating this process in a future version.

### Maintenance

TBA


Configuration
=============

Configuring pg_tier has been simplified by the introduction of two functions designed to handle setting validation and other internals. To see all settings at once, execute this query to examine the contents of the `tier_config` table.

    SELECT config_name, setting FROM tier.tier_config;

There are only a few settings currently that can be modified:

      config_name  | setting  
    ---------------+----------
     root_retain   | 3 Months
     part_period   | 1 Month

In this case, each partition will contain one month of data, and the root table will contain three months before data is moved during maintenance.

To change settings, use the `set_tier_config` function as seen here:

    SELECT tier.set_tier_config('root_retain', '6 Months');

Note that this function *does* check the validity of the setting in question. Here's what would happen if we passed a string that does not represent an interval:

    postgres=# SELECT tier.set_tier_config('root_retain', 'cow');
    ERROR:  cow is not an interval!


Tables
======

The pg_tier extension has a few tables that provide information about its operation and configuration. These tables include:

Table Name | Description
--- | ---
root_retain | A PostgreSQL INTERVAL of how long in days to keep data in the root table before moving it to one of the child partitions. Smallest granularity is one day. Default: 3 months.
part_period | A PostgreSQL INTERVAL dictating the period of time each partition should represent. The smallest granularity is one day. Default: 1 months.


Security
========

Due to its low-level operation, pg_tier works best when executed by a database superuser. However, we understand this is undesirable in many cases. Certain pg_tier capabilities can be assigned to other users by calling `add_tier_admin`. For example:

    CREATE ROLE tier_role;
    SELECT tier.add_tier_admin('tier_role');
    GRANT tier_role TO some_user;

The `tier_role` role can now call any of the tier management functions. These functions should always work, provided the user who created the `tier_manager` extension was a superuser. To revoke access, call the analog function:

    SELECT tier.drop_tier_admin('tier_role');


Build Instructions
==================

To build it, just do this:

    cd pg_tier
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

The `pg_tier` extension has no dependencies other than PostgreSQL.


Copyright and License
=====================

Copyright (c) 2014 OptionsHouse

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
