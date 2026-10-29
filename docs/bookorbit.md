# BookOrbit — initial service

BookOrbit is configured at `https://books.home.hyrax.fyi`. This change prepares
the service only: nothing is copied from `~/vault/books`, and no libraries,
collections, genres, Smart Scopes, or folder reconciliation rules are created.
Plan the import after inspecting the running application.

## Version and network

`modules/services/bookorbit.nix` pins BookOrbit **3.6.0** and the upstream
`pgvector/pgvector:pg18` database image to immutable OCI digests. They run as
Podman containers on a dedicated `bookorbit` bridge with container DNS.
The database has no published port and is independent of Paperless's native
PostgreSQL and InvoiceShelf's MariaDB. The app waits for database readiness;
its upstream entrypoint runs schema migrations before serving requests.

Only `127.0.0.1:8094` is published for Caddy. Private HTTPS, Pi-hole DNS, the
household portal, and unit-failure monitoring are wired in. There are no new
firewall openings, public DNS records, or router forwards. Optional TTS,
read-aloud workers, download clients, and external integrations are not enabled.

Upstream references:

- [Release 3.6.0](https://github.com/bookorbit/bookorbit/releases/tag/v3.6.0)
- [Release container configuration](https://github.com/bookorbit/bookorbit/blob/v3.6.0/docker-compose.yml)
- [Installation](https://bookorbit.app/installation)
- [Collections](https://bookorbit.app/collections)
- [Smart Scopes](https://bookorbit.app/smart-scopes)

## State and permissions

| Host path | Purpose and ownership |
| --- | --- |
| `/srv/bookorbit` | Service root, `root:root 0750` |
| `/srv/bookorbit/data` | Covers and app-managed files, `bookorbit:bookorbit 0750` |
| `/srv/bookorbit/database` | PostgreSQL bind-mount root, `999:999 0700`; mounted at `/var/lib/postgresql`, with image-managed PGDATA in `18/docker` |
| `/srv/media/books` | Empty source library, `root:bookorbit 2770`; mounted at `/books` read-only |
| `/srv/backups/services/bookorbit` | Validated backup generations, `root:homelab-backup 0750` |

The host account and container use UID/GID **1200**. The app runs without root,
with all capabilities dropped, a read-only container filesystem, and writable
`/data` and `/tmp`. It does not recursively change bind-mount ownership.
`spenser-admin` joins `bookorbit` for future administrative transfers; reconnect
SSH after activation to pick up group membership.

The read-only `/books` mount prevents BookOrbit from renaming, editing, uploading
to, or deleting source books. Application-managed staging remains inside
`/data` and is backed up. These restrictions can be revisited during import
planning. Do not enable another writeable library location as a workaround.

PostgreSQL stores accounts, reading progress, metadata (including genres/tags),
collections, Smart Scopes, and application settings. Files alone are not enough
to recover the reading library. Preserve the encrypted SOPS secrets as well.

## Deployment and owner setup

Four independent hex secrets are already encrypted in `secrets/homeserver.yaml`:
`bookorbit/database_password`, `bookorbit/jwt_secret`,
`bookorbit/podcast_encryption_key`, and `bookorbit/setup_bootstrap_token`.
Root-only SOPS templates provide the container environment at runtime; no
plaintext secret enters the Nix store. The setup token is separate from the
administrator password chosen in the browser.

On the server, build and review before activating:

```console
nix flake check --no-build --all-systems
sudo nixos-rebuild build --flake .#homeserver
sudo nixos-rebuild test --flake .#homeserver
sudo systemctl status podman-bookorbit-database.service podman-bookorbit.service
curl --fail http://127.0.0.1:8094/api/v1/health
dig @192.168.4.22 books.home.hyrax.fyi A
curl --fail --location --output /dev/null https://books.home.hyrax.fyi/
```

Open the HTTPS URL on the trusted LAN. Complete the setup wizard using the
bootstrap token from your secret manager or the server's root-only
`/run/secrets/bookorbit/setup_bootstrap_token` file, and choose a unique owner
password. Never paste the token into repository files, issue comments, or logs.
Confirm normal login works and that setup cannot create a second owner.
Inspect registration/access settings before inviting household users.

Stop at the empty-library screen. Do not create the real library or use Book
Dock to import the laptop collection yet. We still need to choose how folders,
collections, genres/tags, and Smart Scopes represent that collection.

Then verify a fresh backup, even with no imported books:

```console
sudo systemctl start bookorbit-backup.service
sudo journalctl --unit bookorbit-backup.service --since today
sudo systemctl start kopia-backup.service
sudo list-homelab-alerts
```

Persist the accepted system with `sudo nixos-rebuild switch --flake .#homeserver`.
No live deployment or application acceptance is implied by local Nix evaluation.

## Backups

Kopia invokes `bookorbit-backup.service` before taking its `/srv/backups`
snapshot. The producer records whether the app is running, stops it while
copying, dumps PostgreSQL in custom format, and archives both application data
and `/srv/media/books`. It then restores the app's previous running state.
Do not run administrative file transfers or direct API/database writers during
this short quiescent period. Book uploads/import planning is deferred anyway.

Each generation contains:

- `database.dump`: accounts, progress, metadata, organizational entities/settings.
- `files.tar.zst`: `data/` and `books/`, including future source books.
- `metadata.json`: application version, image digests, and creation time.
- `SHA256SUMS`: checksums for the three artifacts.

Checksums, the database archive table of contents, and the compressed tar
listing are validated before an atomic directory rename publishes the
generation. Incomplete work is removed on failure; older completed generations
survive. Local generations older than seven days are pruned only after a new
generation succeeds. Once books are imported, this staging method needs space
for the source library plus retained compressed generations; review capacity
and retention during import planning.

Validate a generation without changing the service:

```console
sudo validate-service-bookorbit-backup /srv/backups/services/bookorbit/bookorbit-TIMESTAMP
```

Validation is structural; a successful isolated database restore and application
login test are still required before relying on the service for the collection.
Keep the laptop originals until the future import and restore checks pass.

## Recovery

First restore a chosen Kopia generation beneath `/srv/restore-tests`, validate
it, and inspect its `metadata.json`. Use its pinned app/database versions and
the matching SOPS secrets. Preserve the current database and files separately
before replacing any live state. Never unpack a backup over a running instance.

For an isolated acceptance check, use a disposable pgvector PostgreSQL 18
container/network with no published database port. Create a `bookorbit` role
and empty `bookorbit` database, then restore `database.dump` with PostgreSQL 18
`pg_restore --exit-on-error --no-owner --username=bookorbit --dbname=bookorbit`.
Extract `files.tar.zst` into an empty restore workspace: `data/` becomes the
app's `/data` mount and `books/` becomes `/books` (read-only). Set the recovered
app data to UID/GID 1200, retain restrictive directory modes, and run the
matching app image with the recovered database and JWT/encryption secrets.
Publish the test app only on a different loopback port and use an SSH tunnel.

Check owner login, covers and settings, and (after the eventual import) reading
progress, collections, genres, and Smart Scopes. Use this tested procedure for
live recovery while both original app and database containers are stopped;
start PostgreSQL first, then the app. Do not copy raw PostgreSQL files across
major versions. Image updates require a fresh backup and release/migration
review; changing an environment password alone does not rotate an initialized
PostgreSQL role's password.
