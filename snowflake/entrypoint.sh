#!/bin/bash
set -e

echo "=== Pleasanter SPCS ==="

# ============================================================
# Database credentials (injected as env vars from Snowflake Secrets
# via the SPCS spec's envVarName mapping)
# ============================================================
# Snowflake Postgres allows only built-in roles (snowflake_admin /
# application) for external connections. The actual network-level
# user is always snowflake_admin; the Sa / Owner / User concepts are
# preserved as Postgres roles inside the database and switched into
# via "Options=-c role=..." on the Owner / User connections.
SA_PGUSER=${SA_PGUSER:?SA_PGUSER is required}
SA_PGPASSWORD=${SA_PGPASSWORD:?SA_PGPASSWORD is required}

# PostgreSQL connection settings (from SPCS env vars)
PGHOST=${PGHOST:?PGHOST is required}
PGPORT=${PGPORT:-5432}

# ============================================================
# Build connection strings (passed via env vars at exec)
# ============================================================
# We do NOT rewrite Rds.json. The base image already ships Rds.json with
# Dbms=PostgreSQL and null connection strings, and Pleasanter fills the
# null values from the env vars below (Initializer.CoalesceEmpty), exactly
# like the official docker-compose setup. This keeps the base image's
# curated Rds.json (timeouts etc.) intact and leaves credentials off disk.
#
# "#ServiceName#" is substituted afterward by Initializer.SetRdsParameters()
# with Service.json's "Name" value (baked into the image), so the
# application DB name has a single source of truth.
#
# Owner / User connections authenticate as snowflake_admin and then SET role
# via "Options=-c role=..." so the session identity matches Pleasanter's
# Owner / User design. The schema name (= ServiceName, e.g. "Implem.Pleasanter")
# contains a dot, so it is wrapped in literal double quotes in Search Path to
# be parsed as a single quoted identifier.
SA_CONNECTION_STRING="Server=${PGHOST};Port=${PGPORT};Database=postgres;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true"
OWNER_CONNECTION_STRING="Server=${PGHOST};Port=${PGPORT};Database=#ServiceName#;Search Path='\"#ServiceName#\"';Options=-c role=#ServiceName#_Owner;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true"
USER_CONNECTION_STRING="Server=${PGHOST};Port=${PGPORT};Database=#ServiceName#;Search Path='\"#ServiceName#\"';Options=-c role=#ServiceName#_User;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true"

echo "Connection strings prepared (Sa -> postgres, Owner/User -> #ServiceName# with SET role)"

# Start Pleasanter, injecting the connection strings as env vars.
# The env var names contain dots (Service.Name = "Implem.Pleasanter"), which
# the shell cannot export directly, so we use the `env` command (it accepts
# arbitrary names). Pleasanter reads them via Initializer.CoalesceEmpty.
echo "Starting Pleasanter..."
exec env \
  "Implem.Pleasanter_Rds_PostgreSQL_SaConnectionString=${SA_CONNECTION_STRING}" \
  "Implem.Pleasanter_Rds_PostgreSQL_OwnerConnectionString=${OWNER_CONNECTION_STRING}" \
  "Implem.Pleasanter_Rds_PostgreSQL_UserConnectionString=${USER_CONNECTION_STRING}" \
  dotnet Implem.Pleasanter.dll
