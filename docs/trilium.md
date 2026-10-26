# Trilium trial

TriliumNext is configured at `https://notes.home.hyrax.fyi` for one personal
knowledge base, shared between two desktop clients through the home server.
Joplin and its existing synchronization remain independent of this trial.
This is a trial configuration, not a completed application acceptance test.

## Version and network

The native NixOS `trilium-server` service uses upstream **0.106.1** Linux x64,
pinned by SHA-256 in `modules/services/trilium-package.nix`. Only Trilium's
package is overridden; Nixpkgs and other services remain pinned as before. The
wrapper uses the release's `main.mjs` entry point and bundled Node runtime.

The backend listens on `127.0.0.1:8093`. Caddy supplies HTTPS and forwards
WebSocket, sync, ETAPI, and optional MCP traffic. Only the loopback reverse
proxy is trusted. Pi-hole declares `notes.home.hyrax.fyi`; global firewall ports
remain closed. No public DNS record or router port forward is needed. Remote
access still depends on the separately planned VPN; offline desktop use does not.

Install matching desktop clients from the
[v0.106.1 release](https://github.com/TriliumNext/Trilium/releases/tag/v0.106.1).
Coordinate later server and desktop upgrades. Check protocol compatibility
before adding a third-party Android client; an online phone browser is the
baseline for the initial trial.

## Deployment and initialization

On the server, build and review before activating:

```console
nix flake check --no-build --all-systems
sudo nixos-rebuild build --flake .#homeserver
sudo nixos-rebuild test --flake .#homeserver
sudo systemctl status trilium-server.service caddy.service
dig @192.168.4.22 notes.home.hyrax.fyi A
curl --fail --location --output /dev/null https://notes.home.hyrax.fyi/
```

Complete first-run setup promptly on the trusted home network: the setup wizard
initializes an unclaimed instance. Normal authentication is enabled, but no
owner password is pre-created. Create a **new server collection**, set a unique
password, and keep it in your password manager. Do not point Trilium at Joplin
data. Trilium stores the password and ETAPI tokens in its database, not in Nix.

On laptop A, choose synchronization with an **existing sync server**, using
`https://notes.home.hyrax.fyi` and the server password. Wait for initial sync,
create disposable notes and an attachment, and check the server web UI.
Configure laptop B the same way. Do not initialize two unrelated collections
and expect them to merge. Do not synchronize desktop Trilium data through
Syncthing.

After initialization, run the first backup before relying on the collection:

```console
sudo systemctl start trilium-backup.service
sudo journalctl --unit trilium-backup.service --since today
sudo systemctl start kopia-backup.service
```

The producer deliberately fails on an uninitialized database. Finish onboarding
before the next 04:15 Kopia run; otherwise the required producer prevents a
successful off-host generation. Inspect `sudo list-homelab-alerts` after setup.
Persist the tested system with `sudo nixos-rebuild switch --flake .#homeserver`.

## Laptop acceptance checks

Use disposable notes before importing valuable content:

1. Add/edit notes on each laptop; confirm the other laptop and server receive
   content and attachments. The other laptop need not be online during upload.
2. Disconnect a laptop, fully quit and reopen the desktop app, and read/search
   notes and open an attachment. Edit offline, reconnect, and check the edit
   from the other laptop.
3. Review revision snapshot interval and retention in Options. Save a manual
   revision, then inspect, compare, and restore it through Note revisions.
4. Sync a disposable note to both laptops, disconnect both, and make divergent
   edits, including a deliberate truncation. Reconnect in each order and verify
   displaced content is actually recoverable. Repeat with edits closer together
   than the snapshot interval. Periodic snapshots alone do not prove every
   intermediate edit is retained.
5. Test protected notes if needed. A database backup preserves encrypted
   content, but you still need the appropriate password to open it.
6. Open the web UI from Android while online. Native Android offline clients
   are a later experiment, not a prerequisite for desktop acceptance.

Record versions, results, and recovery gaps before migrating Joplin.

### Implementation verification

On 2026-10-26, the 0.106.1 package built on the x86_64 home server. A disposable
loopback instance served the root application UI, initialized a fresh database,
and rejected anonymous ETAPI access. The backup helper captured and validated
that database (schema 240), and another isolated instance successfully started
from the recovered database. Those processes were stopped; no managed service
was activated. Automated tests also exercise WAL-held content, revisions,
attachment bytes, corruption rejection, and refusal to publish an uninitialized
database. Two-laptop sync/revision acceptance and the deployed HTTPS/MCP paths
remain to be exercised after activation.

## Automation and MCP

Built-in MCP is available but **not enabled automatically**. Create a dedicated
token under **Options → ETAPI**, then enable MCP under **Options → AI / LLM**.
Use the exact endpoint shown by the UI and the assistant's HTTP transport with
that token as a Bearer credential. Store it in the client application's secret
storage, never Git, the Nix store, a portal link, or a committed configuration.
The assistant needs private DNS/HTTPS access on the home network or VPN.

Verify anonymous access to that endpoint is rejected, then connect with the
token and search a disposable note. Test writes only on disposable content.
Do not assume the token is read-only; inspect available tools and revoke it
when finished. MCP does not require an LLM provider configured inside Trilium.

ETAPI is also available to external scripts. Frontend JavaScript works without
server-side scripting. Backend JavaScript and SQL console access are initially
disabled. For a later trusted backend script experiment, set this in the host
configuration and rebuild:

```nix
homelab.trilium.enableBackendScripting = true;
```

Backend JavaScript runs as `trilium`, with access to notes and that account's
permitted filesystem/network resources. The systemd sandbox limits persistent
writes to `/srv/trilium` and private temporary storage. Use the Nix option,
rather than editing generated `config.ini`. Desktop security settings are
separate from server settings.

## State and backup contract

Trilium owns `/srv/trilium` as `trilium:trilium`, mode `0750`:

| Path | Purpose | Recovery |
| --- | --- | --- |
| `document.db` and WAL/SHM sidecars | Notes, revisions, attachments, relationships, credentials, settings | Consistent SQLite backup |
| `config.ini` | Nix-generated configuration symlink | Nix recreates it; contents also backed up |
| `backup/` | Trilium's local database backups | Extra local recovery layer; not Kopia staging |
| `log/`, `tmp/`, caches | Runtime/reconstructable data | Excluded |

Before each Kopia generation, `trilium-backup.service` uses SQLite's online
backup API to capture a consistent database, including committed changes still
in the live WAL. It does not copy a running database with `cp` or interrupt
sync. It converts the destination to a standalone database, copies config
contents, checks integrity/initialization, and records app/schema versions,
table counts, and SHA-256 checksums.

Validated generations are atomically published beneath
`/srv/backups/services/trilium/trilium-TIMESTAMP/`, containing `document.db`,
`config.ini`, and `metadata.json`. Local generations older than seven days are
removed only after successful publication. Kopia supplies encrypted off-host
retention. Integrity checks do not substitute for application-level recovery.
Service and backup failures feed the existing monitoring alerts.

## Isolated recovery drill

Restore a Kopia snapshot into a new directory beneath `/srv/restore-tests`
following [backup-and-restore.md](./backup-and-restore.md). Validate a recovered
generation, replacing the placeholders with actual directory names:

```console
sudo validate-service-trilium-backup \
  /srv/restore-tests/kopia-YYYYMMDD/services/trilium/trilium-TIMESTAMP
```

This checks checksums, SQLite integrity, initialization, schema version, and
table counts without modifying the live database. Metadata records the version
required for an application recovery test.

For that test, create a separate empty directory owned by the administrator,
outside `/srv/trilium`, and copy **only** recovered `document.db` there. Run the
matching pinned binary with an isolated data directory and loopback port:

```console
TRILIUM_DATA_DIR=/path/to/isolated-trilium \
TRILIUM_NETWORK_HOST=127.0.0.1 \
TRILIUM_NETWORK_PORT=8094 \
TRILIUM_SYNC_SYNCSERVERHOST= \
TRILIUM_GENERAL_NOBACKUP=true \
TRILIUM_SECURITY_BACKEND_SCRIPTING_ENABLED=false \
TRILIUM_SECURITY_SQL_CONSOLE_ENABLED=false \
  /nix/store/REVIEWED-TRILIUM-PACKAGE/bin/trilium-server
```

Use an SSH tunnel to port 8094, sign in, and verify a note, attachment, and
revision. Keep this foreground process separate from the managed service. Do
not connect desktop clients or assistants to the recovery copy. For a fully
isolated drill, also block outbound networking so restored integrations cannot
contact production systems.

For disaster recovery, stop the service, preserve the old state directory,
and restore into a **new empty** `/srv/trilium`. Do not overwrite a live database
or leave old `document.db-wal`/`document.db-shm` beside it. Restore ownership to
`trilium:trilium`, let Nix recreate `config.ini`, start the matching application
version, and validate before reconnecting clients. Back up before upgrading:
a NixOS rollback does not roll back database migrations.

## References

- [Release and desktop downloads](https://github.com/TriliumNext/Trilium/releases/tag/v0.106.1)
- [Synchronization](https://docs.triliumnotes.org/user-guide/setup/synchronization)
- [Revisions](https://docs.triliumnotes.org/user-guide/concepts/notes/note-revisions)
- [MCP](https://docs.triliumnotes.org/user-guide/llm/mcp)
- [ETAPI](https://docs.triliumnotes.org/user-guide/advanced-usage/etapi)
