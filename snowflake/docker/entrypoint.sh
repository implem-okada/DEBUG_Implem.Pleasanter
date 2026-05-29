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
# Generate Rds.json dynamically
# ============================================================
# Same role / search_path layout as the CodeDefiner container. The
# "#ServiceName#" placeholder is substituted at startup by
# Initializer.SetRdsParameters() with Service.json's "Name" value,
# which is baked into the image -- so the application DB name has
# a single source of truth and cannot drift between containers.
#
# Owner / User connections authenticate as snowflake_admin and then
# SET role via "Options=-c role=..." so the session identity matches
# Pleasanter's Owner / User design.
cat > /app/App_Data/Parameters/Rds.json << EOF
{
  "Dbms": "PostgreSQL",
  "Provider": "Local",
  "SaConnectionString": "Server=${PGHOST};Port=${PGPORT};Database=postgres;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true",
  "OwnerConnectionString": "Server=${PGHOST};Port=${PGPORT};Database=#ServiceName#;Search Path='\"#ServiceName#\"';Options=-c role=#ServiceName#_Owner;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true",
  "UserConnectionString": "Server=${PGHOST};Port=${PGPORT};Database=#ServiceName#;Search Path='\"#ServiceName#\"';Options=-c role=#ServiceName#_User;uid=${SA_PGUSER};pwd=${SA_PGPASSWORD};SSL Mode=Require;Trust Server Certificate=true",
  "SqlCommandTimeOut": 600,
  "MinimumTime": 10,
  "DeadlockRetryCount": 4,
  "DeadlockRetryInterval": 1000
}
EOF

echo "Generated Rds.json:"
cat /app/App_Data/Parameters/Rds.json | sed 's/pwd=[^;]*/pwd=****/g'

# Start Pleasanter
echo "Starting Pleasanter..."
exec dotnet Implem.Pleasanter.dll
