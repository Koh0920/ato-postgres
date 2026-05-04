# ato-postgres

PostgreSQL `service@1` provider capsule for the [ato](https://github.com/ato-run/ato)
dependency-contract grammar (RFC `CAPSULE_DEPENDENCY_CONTRACTS.md` v1.6).

Use from another capsule:

```toml
[dependencies.db]
capsule  = "capsule://github.com/Koh0920/ato-postgres@<commit-sha>"
contract = "service@1"

[dependencies.db.parameters]
database = "myapp"

[dependencies.db.credentials]
password = "{{env.PG_PASSWORD}}"

[dependencies.db.state]
name = "data"
```

## Requirements

The bootstrap script invokes the host's PostgreSQL binaries:

- `/opt/homebrew/bin/postgres`, `/opt/homebrew/bin/initdb`,
  `/opt/homebrew/bin/createdb`, `/opt/homebrew/bin/pg_ctl`,
  `/opt/homebrew/bin/pg_isready`

Install via Homebrew on macOS:

```
brew install postgresql@14
```

## Notes

- Postgres runs **TCP-only** (`unix_socket_directories=''`) because the
  ato state.dir path under `<ato_home>/state/<parent>/<instance_hash>/...`
  exceeds the macOS 103-byte sun_path limit.
- The credential is materialized via Rule M1 TempFile with mode 0600
  and unlinked after provision.
- State path is per-parent, per-instance, per-state-version (`state.version = "16"`).
