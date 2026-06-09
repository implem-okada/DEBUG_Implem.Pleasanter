#!/bin/bash
set -e

echo "=== Pleasanter CodeDefiner (SPCS) ==="

# ============================================================
# Database credentials (injected as env vars from Snowflake Secrets
# via the SPCS spec's envVarName mapping)
# ============================================================
# Snowflake Postgres allows only built-in roles (snowflake_admin /
# application) for external connections, so the actual network-level
# user is always snowflake_admin. The Sa / Owner / User concepts are
# preserved as Postgres roles inside the database, and the Owner /
# User connections use Npgsql's "Options=-c role=..." to SET role
# right after authentication.
SA_PGUSER=${SA_PGUSER:?SA_PGUSER is required}
SA_PGPASSWORD=${SA_PGPASSWORD:?SA_PGPASSWORD is required}

# PostgreSQL connection settings (from SPCS env vars)
PGHOST=${PGHOST:?PGHOST is required}
PGPORT=${PGPORT:-5432}

# ============================================================
# Build connection strings (passed via env vars at exec, see bottom)
# ============================================================
# We do NOT rewrite Rds.json. The base image already ships Rds.json with
# Dbms=PostgreSQL and null connection strings, and CodeDefiner fills the
# null values from the env vars below (Initializer.CoalesceEmpty), exactly
# like the official docker-compose setup.
#
# Standard Pleasanter convention:
#   Sa    -> system DB "postgres". Used by CodeDefiner to CREATE the
#            application DB on first run.
#   Owner -> application DB, acts as <ServiceName>_Owner. Used for DDL.
#   User  -> application DB, acts as <ServiceName>_User. Used for DML.
#
# All three authenticate as snowflake_admin (Snowflake's external-auth
# restriction). For Owner / User, "Options=-c role=#ServiceName#_Owner"
# / "_User" tells Postgres to SET role immediately after the startup
# handshake, so the rest of the session runs with the proper identity
# and object-ownership semantics.
#
# "#ServiceName#" is substituted at startup by
# Initializer.SetRdsParameters() with Service.json's "Name" value --
# the single source of truth, baked into the image.
#
# Search Path quoting note: the schema name (= ServiceName, e.g.
# "Implem.Pleasanter") contains a dot. PostgreSQL's search_path GUC
# parses its value as a comma-separated identifier list, and unquoted
# identifiers may not contain dots ("schema.relation" form would be
# ambiguous). We therefore wrap the value in literal double quotes so
# Postgres reads it as a single quoted identifier with a dot inside.
# The outer single quotes are the ADO.NET connection-string syntax
# for "value that itself contains double quotes"; they are stripped
# by the parser and the doubled double quotes are passed through to
# Npgsql -> Postgres as "Implem.Pleasanter".
# (libpq's "-c role=..." does NOT need this treatment because GUC role
# lookup matches the rolname string exactly, with no list parsing.)
SA_CONNECTION_STRING="Server=${PGHOST};Port=${PGPORT};Database=postgres;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true"
OWNER_CONNECTION_STRING="Server=${PGHOST};Port=${PGPORT};Database=#ServiceName#;Search Path='\"#ServiceName#\"';Options=-c role=#ServiceName#_Owner;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true"
USER_CONNECTION_STRING="Server=${PGHOST};Port=${PGPORT};Database=#ServiceName#;Search Path='\"#ServiceName#\"';Options=-c role=#ServiceName#_User;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true"

echo "Connection strings prepared (Sa -> postgres, Owner/User -> #ServiceName# with SET role; passwords masked):"
echo "  Sa   : $(echo "$SA_CONNECTION_STRING"    | sed 's/pwd=[^;]*/pwd=****/')"
echo "  Owner: $(echo "$OWNER_CONNECTION_STRING" | sed 's/pwd=[^;]*/pwd=****/')"
echo "  User : $(echo "$USER_CONNECTION_STRING"  | sed 's/pwd=[^;]*/pwd=****/')"

# ============================================================
# Patch SQL files for Snowflake Postgres compatibility
# ============================================================
# Snowflake Postgres requires every external connection to authenticate
# as snowflake_admin, but Pleasanter's standard DDL assumes a separate
# Sa / Owner / User user per connection. The patches below bridge that
# gap by:
#   - swapping connection-string-derived placeholders (#Uid_Owner# etc.,
#     which all resolve to "snowflake_admin" here) for hard-coded role
#     names derived from #SchemaName# (e.g. "Implem.Pleasanter_Owner");
#   - no-oping statements that would ALTER snowflake_admin (Snowflake
#     blocks that on built-in roles).
# Custom roles still exist inside Postgres -- they just can't be the
# auth principal of the connection.
SQL_DIR="/app/Implem.Pleasanter/App_Data/Definitions/Sqls/PostgreSQL"

# ------------------------------------------------------------
# SpWho.sql: Exclude current PID to prevent self-termination
# ------------------------------------------------------------
if [ -f "$SQL_DIR/SpWho.sql" ]; then
    sed -i "s/where usename = '#Uid#'/where usename = '#Uid#' and pid != pg_backend_pid()/" "$SQL_DIR/SpWho.sql"
    echo "  Patched SpWho.sql"
fi

# ------------------------------------------------------------
# AlterLoginRole.sql: ALTER ROLE WITH PASSWORD on snowflake_admin
# is blocked by Snowflake. UsersConfigurator.Execute() calls this
# for the Owner / User connections (both have uid=snowflake_admin
# under Option B), so we no-op it.
# ------------------------------------------------------------
if [ -f "$SQL_DIR/AlterLoginRole.sql" ]; then
    echo "SELECT 1;" > "$SQL_DIR/AlterLoginRole.sql"
    echo "  Patched AlterLoginRole.sql (no-op)"
fi

# ------------------------------------------------------------
# GrantPrivilegeAdmin.sql: The original runs ALTER ROLE on
# snowflake_admin, which is blocked. PrivilegeConfigurator only
# routes to this branch when uid ends with "_Owner", which never
# happens in our setup (uid is always snowflake_admin), so the
# no-op is purely defensive.
# ------------------------------------------------------------
if [ -f "$SQL_DIR/GrantPrivilegeAdmin.sql" ]; then
    echo "SELECT 1;" > "$SQL_DIR/GrantPrivilegeAdmin.sql"
    echo "  Patched GrantPrivilegeAdmin.sql (no-op)"
fi

# ------------------------------------------------------------
# ChangeDatabaseOwnerForPostgres.sql: The DB owner is already
# set to "#SchemaName#_Owner" by our patched
# CreateDatabaseForPostgres.sql, so the original
# "ALTER DATABASE ... OWNER TO #Uid_Owner#" (which would target
# snowflake_admin here) is redundant.
# ------------------------------------------------------------
if [ -f "$SQL_DIR/ChangeDatabaseOwnerForPostgres.sql" ]; then
    echo "SELECT 1;" > "$SQL_DIR/ChangeDatabaseOwnerForPostgres.sql"
    echo "  Patched ChangeDatabaseOwnerForPostgres.sql (no-op)"
fi

# ------------------------------------------------------------
# CreateUserForPostgres.sql: Create the Pleasanter Owner / User
# roles named "#SchemaName#_Owner" / "#SchemaName#_User" and
# grant them to the current Sa session user so it can SET role
# into them.
#
# We deliberately use current_user instead of the "#Uid_Sa#"
# placeholder: RdsConfigurator only substitutes "#Uid_Sa#" in
# the CreateDatabase path, not in UpdateDatabase, so a literal
# "#Uid_Sa#" would survive into the SQL on every re-run (= role
# "#Uid_Sa#" does not exist). current_user is always available
# and is exactly the role we want to grant the new roles to.
#
# The new roles are created with NOLOGIN -- they will never be
# the auth principal of a connection (Snowflake blocks that for
# anything but snowflake_admin / application). They exist purely
# to own objects and gate privileges via SET role.
# ------------------------------------------------------------
if [ -f "$SQL_DIR/CreateUserForPostgres.sql" ]; then
    cat > "$SQL_DIR/CreateUserForPostgres.sql" << 'SQLEOF'
do $xxx$
declare
  v_owner text := '#SchemaName#_Owner';
  v_user  text := '#SchemaName#_User';
  v_sa    text := current_user;
begin
  if '#SchemaName#' <> 'public' then
     revoke create on schema public from public;
  end if;
  if not exists (select 1 from pg_roles where rolname = v_owner) then
     execute format('create role %I nologin', v_owner);
  end if;
  if not exists (select 1 from pg_roles where rolname = v_user) then
     execute format('create role %I nologin', v_user);
  end if;
  execute format('grant %I to %I', v_owner, v_sa);
  execute format('grant %I to %I', v_user,  v_sa);
end $xxx$
;
SQLEOF
    echo "  Patched CreateUserForPostgres.sql"
fi

# ------------------------------------------------------------
# CreateDatabaseForPostgres.sql: Make the new application DB
# owned by "#SchemaName#_Owner" (not by the auth principal,
# which would be snowflake_admin without the patch).
#
# CodeDefiner runs CreateUserForPostgres BEFORE this, so the
# Owner / User roles already exist when we reference them.
# ------------------------------------------------------------
if [ -f "$SQL_DIR/CreateDatabaseForPostgres.sql" ]; then
    cat > "$SQL_DIR/CreateDatabaseForPostgres.sql" << 'SQLEOF'
create database "#InitialCatalog#" owner "#SchemaName#_Owner";

do $$
begin
  if exists (select 'public' != '#SchemaName#') then
     revoke all on database "#InitialCatalog#" from public;
  end if;
end $$ ;

grant all privileges on database "#InitialCatalog#" to "#SchemaName#_Owner";
grant connect, temporary on database "#InitialCatalog#" to "#SchemaName#_User";
SQLEOF
    echo "  Patched CreateDatabaseForPostgres.sql"
fi

# ------------------------------------------------------------
# CreateSchema.sql: Authorize the schema to the Owner role and
# grant USAGE to the User role (matches Pleasanter's standard
# layout). The original uses #Uid_Owner# / #Uid_User#, both of
# which would resolve to snowflake_admin in our setup.
#
# "WITH SCHEMA" pins the extensions to the application schema so
# we never depend on search_path resolving to a writable schema
# (which can be empty if we end up in an inconsistent state).
# ------------------------------------------------------------
if [ -f "$SQL_DIR/CreateSchema.sql" ]; then
    cat > "$SQL_DIR/CreateSchema.sql" << 'SQLEOF'
create schema "#SchemaName#" authorization "#SchemaName#_Owner";
grant usage on schema "#SchemaName#" to "#SchemaName#_User";
create extension if not exists pg_trgm  with schema "#SchemaName#";
create extension if not exists pgcrypto with schema "#SchemaName#";
SQLEOF
    echo "  Patched CreateSchema.sql"
fi

# ------------------------------------------------------------
# GrantDatabaseForPostgres.sql: Same fix as CreateSchema.sql,
# but for the "DB already exists" path (SchemaConfigurator
# routes here when IsCreatingDb is false).
# ------------------------------------------------------------
if [ -f "$SQL_DIR/GrantDatabaseForPostgres.sql" ]; then
    cat > "$SQL_DIR/GrantDatabaseForPostgres.sql" << 'SQLEOF'
grant usage on schema "#SchemaName#" to "#SchemaName#_User";
create extension if not exists pg_trgm  with schema "#SchemaName#";
create extension if not exists pgcrypto with schema "#SchemaName#";
SQLEOF
    echo "  Patched GrantDatabaseForPostgres.sql"
fi

# ------------------------------------------------------------
# GrantPrivilegeUser.sql: Iterate over Owner-owned tables in
# the application schema and grant DML to the User role.
#
# In our setup PrivilegeConfigurator routes BOTH iterations
# (Owner and User connections) here because neither uid ends
# with "_Owner". Our patch ignores #Uid# / #Oid# (which would
# be snowflake_admin) and hard-codes the role pair derived
# from #SchemaName#. Idempotent re-grant on the second call.
# ------------------------------------------------------------
if [ -f "$SQL_DIR/GrantPrivilegeUser.sql" ]; then
    cat > "$SQL_DIR/GrantPrivilegeUser.sql" << 'SQLEOF'
do
$$
declare
    r record;
begin
    for r in
        select schemaname, tablename
        from pg_tables
        where tableowner = '#SchemaName#_Owner'
          and schemaname = '#SchemaName#'
    loop
        execute 'grant select, insert, update, delete on table "'
                || r.schemaname || '"."' || r.tablename
                || '" to "#SchemaName#_User"';
    end loop;
end
$$;
SQLEOF
    echo "  Patched GrantPrivilegeUser.sql"
fi

echo "All Snowflake Postgres patches applied"

# Run CodeDefiner. It will, on first run:
#   1. Sa creates DB "#ServiceName#" owned by "#ServiceName#_Owner".
#   2. Sa creates the "_Owner" / "_User" roles (NOLOGIN) and grants
#      them to snowflake_admin.
#   3. Owner (snowflake_admin SET role to "_Owner") creates the
#      schema and the tables, which therefore end up owned by the
#      "_Owner" role.
#   4. PrivilegeConfigurator grants DML on those tables to "_User".
# Inject the connection strings as env vars (CoalesceEmpty fills Rds.json's
# null values). The env var names contain dots (Service.Name =
# "Implem.Pleasanter"), which the shell cannot export directly, so we use
# the `env` command (it accepts arbitrary names).
cd /app/Implem.CodeDefiner
exec env \
  "Implem.Pleasanter_Rds_PostgreSQL_SaConnectionString=${SA_CONNECTION_STRING}" \
  "Implem.Pleasanter_Rds_PostgreSQL_OwnerConnectionString=${OWNER_CONNECTION_STRING}" \
  "Implem.Pleasanter_Rds_PostgreSQL_UserConnectionString=${USER_CONNECTION_STRING}" \
  dotnet Implem.CodeDefiner.dll _rds /y
