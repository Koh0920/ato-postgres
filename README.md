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

This capsule has **no host PostgreSQL dependency**. PostgreSQL binaries
come from ato-cli's verified tool artifact resolver
([ato-run/ato#119][ato119], [ato-run/ato#120][ato120]). The capsule
declares `tool_artifacts = ["postgresql"]` under `[targets.server]`;
ato-cli (≥ 0.5.x):

1. downloads the pinned PostgreSQL distribution (zonky-test/embedded-postgres-binaries
   16.9.0 darwin-arm64v8 today; Linux/x86_64 follow-ups land in
   ato-cli's built-in registry as the pins are validated)
2. sha256-verifies the bytes before unpack
3. unpacks into `$ATO_HOME/store/tools/postgresql-<platform>-<sha-prefix>/`
4. injects the resolved paths into the provider environment as

   ```
   ATO_TOOL_POSTGRES_ROOT
   ATO_TOOL_POSTGRES_BIN_DIR
   ATO_TOOL_POSTGRES_LIB_DIR
   ATO_TOOL_POSTGRES_SHARE_DIR
   ATO_TOOL_INITDB
   ATO_TOOL_POSTGRES
   ATO_TOOL_PG_CTL
   ```

`bootstrap.sh` consumes those env vars and exits 78 (EX_CONFIG) with a
clear message if any are missing — older ato-cli versions
(< 0.5.x) are not supported. Readiness is the orchestrator's
`ReadyProbeKind::Postgres` (no `pg_isready` binary required).

## Notes

- Postgres runs **TCP-only** (`unix_socket_directories=''`) because the
  ato state.dir path under `<ato_home>/state/<parent>/<instance_hash>/...`
  exceeds the macOS 103-byte sun_path limit.
- The credential is materialized via Rule M1 TempFile with mode 0600
  and unlinked after provision.
- State path is per-parent, per-instance, per-state-version (`state.version = "16"`).
- `createdb` and `psql` are intentionally **not** part of the artifact
  (zonky's relocatable distribution ships only `initdb`, `postgres`,
  `pg_ctl`). One-shot init SQL runs through `postgres --single` —
  network-less, authentication-less mode designed for exactly this use.

[ato119]: https://github.com/ato-run/ato/issues/119
[ato120]: https://github.com/ato-run/ato/issues/120
