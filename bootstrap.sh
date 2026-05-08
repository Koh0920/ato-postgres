#!/bin/bash
# Postgres provider bootstrap.
#
# Args: $1 = state_dir, $2 = port, $3 = path to credential file
#
# RFC §7.3.2 Rule M1: the credential is materialized as a temp file with
# 0600 perms. The password file is unlinked by the orchestrator at
# teardown.
#
# Tool binaries: this capsule declares `tool_artifacts = ["postgresql"]`
# in capsule.toml. ato-cli (≥ 0.5.x) downloads + sha256-verifies the
# pinned upstream Postgres distribution into $ATO_HOME/store/tools/...
# and injects the resolved paths via env. We require the env vars
# below — if any are missing, ato-cli is older than 0.5.x and this
# capsule cannot run on this host. Older ato-cli versions called
# /opt/homebrew/bin/* directly; that contract is removed (see
# ato-run/ato#119, #120).
#
# Password lifecycle:
#   - First init: initdb --pwfile=<path> bakes PG_PASSWORD into pg_authid.
#   - Subsequent starts: ato may pass a different PG_PASSWORD (e.g. the
#     user runs PG_PASSWORD=$(openssl rand -hex 16) per invocation, or
#     rotates the secret deliberately). We rewrite pg_authid via single-
#     user mode (`postgres --single`) before the regular postmaster
#     starts, so the consumer's psycopg.connect(DATABASE_URL) always
#     uses the same value as ato's runtime_exports template.

set -eu

STATE_DIR="$1"
PORT="$2"
PWFILE="$3"

require_tool_env() {
  local var="$1"
  local val="${!var:-}"
  if [ -z "$val" ]; then
    echo "[ato/postgres bootstrap] FATAL: $var is unset." >&2
    echo "[ato/postgres bootstrap] This capsule requires ato-cli >= 0.5.x with the tool artifact resolver." >&2
    echo "[ato/postgres bootstrap] Older ato-cli versions injected /opt/homebrew/bin/* directly; that path is removed." >&2
    exit 78  # EX_CONFIG
  fi
  if [ ! -x "$val" ]; then
    echo "[ato/postgres bootstrap] FATAL: $var=$val is not executable." >&2
    exit 78
  fi
}

require_tool_env ATO_TOOL_INITDB
require_tool_env ATO_TOOL_POSTGRES
require_tool_env ATO_TOOL_PG_CTL

PGDATA="${STATE_DIR}/pgdata"

# Postgres Unix-domain socket path is bounded to 103 bytes on macOS. State
# dirs derived from <ato_home>/<parent>/<hash>/<state.version>/<state.name>/
# routinely exceed that. We disable Unix sockets entirely (TCP-only) by
# setting unix_socket_directories = '' on every postgres invocation.

PG_OPTS=(
  "-c" "listen_addresses=127.0.0.1"
  "-c" "unix_socket_directories="
)

if [ ! -f "${PGDATA}/PG_VERSION" ]; then
  echo "[ato/postgres bootstrap] initdb at ${PGDATA}" >&2
  "${ATO_TOOL_INITDB}" \
    -D "${PGDATA}" \
    --encoding=UTF8 \
    --username=postgres \
    --auth-local=password \
    --auth-host=password \
    --pwfile="${PWFILE}" \
    --no-instructions >&2

  if [ -n "${ATO_PG_DATABASE:-}" ]; then
    # The verified Postgres tool artifact deliberately omits `createdb`
    # and `psql` (zonky's relocatable distribution ships only initdb,
    # postgres, pg_ctl). Use postgres single-user mode (`--single`) to
    # run the CREATE DATABASE SQL directly against the catalog —
    # network-less, authentication-less, intended exactly for one-shot
    # init.
    echo "[ato/postgres bootstrap] creating database ${ATO_PG_DATABASE} via postgres --single" >&2
    echo "CREATE DATABASE \"${ATO_PG_DATABASE}\";" | \
      "${ATO_TOOL_POSTGRES}" --single \
        -D "${PGDATA}" \
        -c unix_socket_directories= \
        postgres >&2
  fi
  echo "[ato/postgres bootstrap] init complete" >&2
else
  # Cluster already exists from a previous run. ato may have rotated
  # PG_PASSWORD since then, so the password baked into pg_authid no
  # longer matches what ato just materialized into PWFILE. Rewrite
  # pg_authid via single-user mode (`postgres --single`) before the
  # regular postmaster starts — no network, no auth required, and no
  # risk of leaking the new credential over a transient socket the
  # consumer might also touch.
  if [ -s "${PWFILE}" ]; then
    NEW_PASSWORD="$(cat "${PWFILE}")"
    # SQL string-literal escape: double every single quote so a
    # password containing ' doesn't break out of the literal.
    ESCAPED_PASSWORD="${NEW_PASSWORD//\'/\'\'}"
    echo "[ato/postgres bootstrap] aligning postgres password with current PG_PASSWORD" >&2
    if ! printf "ALTER ROLE postgres WITH PASSWORD '%s';\n" "${ESCAPED_PASSWORD}" \
         | "${ATO_TOOL_POSTGRES}" --single \
            -D "${PGDATA}" \
            -c unix_socket_directories= \
            postgres >&2; then
      echo "[ato/postgres bootstrap] WARN: password rotation failed — auth may fail downstream" >&2
    fi
  fi
fi

echo "[ato/postgres bootstrap] starting postgres on 127.0.0.1:${PORT}" >&2
exec "${ATO_TOOL_POSTGRES}" \
  -D "${PGDATA}" \
  -p "${PORT}" \
  "${PG_OPTS[@]}"
