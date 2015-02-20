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

The pg_tier extension works by maintaining a base table and all children based on some very simple constraints. Let's make a very basic schema now:

    CREATE SCHEMA comm;

    CREATE TABLE comm.yell (
      id          SERIAL PRIMARY KEY NOT NULL,
      message     TEXT NOT NULL,
      created_dt  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
    );

That was easy! Now, to use pg_tier, there are three basic steps:

* Registration
* Creation
* Initialization


Configuration
=============

Configuring pg_tier has been simplified by the introduction of two functions designed to handle setting validation and other internals. To see all settings at once, execute this query to examine the contents of the `tier_config` table.

    SELECT config_name, setting FROM tier.tier_config;




Tables
======

The pg_tier extension has a few tables that provide information about its operation and configuration. These tables include:

Table Name | Description
--- | ---
tier_config | Contains all settings pg_tier uses to control tier allocation.
tier_map | Maintains a physical/logical mapping for applications to find tiers. Tracks whether tiers have been initialized for use.
tier_table | Master resource where all registered tier tables are tracked. Every schema can have its own list of tables.


Security
========

Due to its low-level operation, pg_tier works best when executed by a database superuser. However, we understand this is undesirable in many cases. Certain pg_tier capabilities can be assigned to other users by calling `add_tier_admin`. For example:

    CREATE USER tier_user;
    SELECT tier.add_tier_admin('tier_user');

This user can now call any of the tier management functions. These functions should always work, provided the user who created the `tier_manager` extension was a superuser. To revoke access, call the analog function:

    SELECT tier.drop_tier_admin('tier_user');


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
