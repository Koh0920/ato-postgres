#!/bin/bash
# Postgres provider bootstrap for P7 (since [provision] block execution
# is deferred from v1 MVP, we embed init-or-exec in this wrapper script).
#
# Args: $1 = state_dir, $2 = port, $3 = path to credential file
#
# RFC §7.3.2 Rule M1: the credential is materialized as a temp file with
# 0600 perms. The password file is unlinked by the orchestrator at
# teardown.
#
# Password lifecycle:
#   - First init: initdb --pwfile=<path> bakes PG_PASSWORD into pg_authid.
#   - Subsequent starts: ato may pass a different PG_PASSWORD (e.g. the
#     user runs PG_PASSWORD=$(openssl rand -hex 16) per invocation, or
#     rotates the secret deliberately). We rewrite pg_authid via single-
#     user mode (`postgres --single`) before the regular postmaster
#     starts, so the consumer's psycopg.connect(DATABASE_URL) always
#     uses the same value as ato's runtime_exports template. Without
#     this, a password mismatch surfaces only as a generic
#     `FATAL: password authentication failed for user "postgres"` from
#     the consumer's lifespan and every subsequent run breaks until the
#     user manually wipes the state dir.

set -eu

STATE_DIR="$1"
PORT="$2"
PWFILE="$3"

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
  /opt/homebrew/bin/initdb \
    -D "${PGDATA}" \
    --encoding=UTF8 \
    --username=postgres \
    --auth-local=password \
    --auth-host=password \
    --pwfile="${PWFILE}" \
    --no-instructions >&2
  if [ -n "${ATO_PG_DATABASE:-}" ]; then
    echo "[ato/postgres bootstrap] creating database ${ATO_PG_DATABASE}" >&2
    /opt/homebrew/bin/pg_ctl \
      -D "${PGDATA}" \
      -l "${PGDATA}/init.log" \
      -o "-p ${PORT} ${PG_OPTS[*]}" \
      -w start
    PGPASSWORD="$(cat "${PWFILE}")" \
      /opt/homebrew/bin/createdb \
      -h 127.0.0.1 -p "${PORT}" -U postgres \
      "${ATO_PG_DATABASE}"
    /opt/homebrew/bin/pg_ctl -D "${PGDATA}" -m fast stop
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
         | /opt/homebrew/bin/postgres --single \
            -D "${PGDATA}" \
            -c unix_socket_directories= \
            postgres >&2; then
      echo "[ato/postgres bootstrap] WARN: password rotation failed — auth may fail downstream" >&2
    fi
  fi
fi

echo "[ato/postgres bootstrap] starting postgres on 127.0.0.1:${PORT}" >&2
exec /opt/homebrew/bin/postgres \
  -D "${PGDATA}" \
  -p "${PORT}" \
  "${PG_OPTS[@]}"
