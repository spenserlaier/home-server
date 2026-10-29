# Backup and restore

The host creates application-consistent artifacts below `/srv/backups`, then
captures that entire staging tree as one encrypted Kopia snapshot in the
dedicated `hyrax-home-server` Backblaze bucket. The Git repository reconstructs
the operating system; Kopia reconstructs service data.

BookOrbit adds `bookorbit-backup.service` to the required producers. It publishes
validated PostgreSQL dumps and application/source-file archives under
`services/bookorbit`. The initial source library is empty; no laptop books are
imported. See [bookorbit.md](./bookorbit.md) for owner setup and recovery.

The Trilium trial adds `trilium-backup.service` to the required producers. It
publishes validated SQLite database generations (including revisions and
attachments) under `services/trilium`. Initialize the trial before its first
scheduled backup; the producer rejects an uninitialized database. See
[trilium.md](./trilium.md) for two-laptop acceptance and isolated recovery.

Kopia uses Backblaze's S3-compatible endpoint in `us-east-005`. Repository
contents are encrypted by Kopia before upload. Backblaze's bucket encryption is
an additional storage-side layer, not a replacement for the repository
password.

## Backup browser

Open **Backups** in the dashboard's **Administration** section, or visit
`https://backups.home.hyrax.fyi`. Sign in as `admin` using the distinct
`kopia/ui_password` secret in SOPS. Retrieve it on the administrative laptop:

```console
sops decrypt --extract '["kopia"]["ui_password"]' secrets/homeserver.yaml
```

Show snapshots from all users/hosts if needed to find `root@homeserver:/srv/backups`,
then choose a snapshot and browse `services/<service>`. Individual
files can be downloaded to your browser. ZIP and compressed TAR artifacts must
be downloaded or restored before inspecting their contents; Kopia does not
browse inside application archives.

The UI connects to the existing B2 repository read-only and refreshes repository
status every five minutes. Backup creation, retention, and verification remain
owned by the existing systemd jobs. Mutation controls may still be visible in
Kopia, but repository writes are rejected. The UI login grants access to all
decrypted service backups; it is an administrative account.

For server-side restores, select a **new** destination beneath
`/srv/kopia-ui/restores`, such as `/srv/kopia-ui/restores/2026-10-20-paperless`.
Disable **Restore File Ownership** when restoring through the UI: the service
runs unprivileged and cannot reproduce the original root-owned files' owners.
These files belong to `kopia-ui` and require administrator access outside the UI.
The dedicated service identity and filesystem sandbox prevent restoring over
live application data. Repository read-only access does not prevent writing
restored files locally. The cache, runtime connection, and restore workspace
are excluded from backups and are not needed for disaster recovery. Remove
unneeded restored files after inspection; the workspace has no automatic cleanup.
Application-level validation and recovery still follow the procedures below.

The backend listens only on `127.0.0.1:51515`; Caddy provides private HTTPS and
Kopia requires authentication. Pi-hole declares the `backups` DNS record. On a
client using a different resolver, add the same private record there.

After deployment, verify:

```console
sudo systemctl status kopia-ui.service
sudo journalctl --unit kopia-ui.service --since today
dig @192.168.4.22 backups.home.hyrax.fyi A
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  https://backups.home.hyrax.fyi/api/v1/snapshots
```

DNS must return `192.168.4.22`, and the anonymous API request must return `401`.
Sign in, browse a historical snapshot, download a small artifact, and restore a
service subtree to a new workspace directory. Confirm that the repository is
read-only and the existing Kopia backup and verification timers remain active.
If the bucket has not been initialized, the UI retries its connection every
30 seconds; initialize it using the explicit procedure below.

## Retention model

Kopia applies a 30-day compliance Object Lock to every repository blob. Object
Lock must be enabled on the bucket, but bucket-default retention should remain
disabled: Kopia supplies the per-object duration. Compliance mode is deliberate
for this dedicated bucket: a lock cannot be shortened or bypassed, even by an
administrator or a credential with `bypassGovernance` capability.

Snapshot retention and object immutability are separate controls. The declared
snapshot policy keeps 10 latest, 7 daily, 4 weekly, 12 monthly, and 3 annual
snapshots. Expired snapshot metadata can stop being retained before locked
storage objects become physically deletable.

Use a Backblaze `Read and Write` application key restricted to
`hyrax-home-server`. Do not grant it access to other buckets. Backblaze's UI
permission bundle is broader than Kopia strictly requires, but compliance mode
prevents that key's `bypassGovernance` capability from shortening object locks.

## Initialize the repository once

After the first deployment, initialize the empty bucket explicitly:

```console
sudo systemctl start kopia-repository-init.service
sudo systemctl status kopia-repository-init.service
sudo journalctl --unit kopia-repository-init.service --since today
```

The initializer is intentionally not enabled or started automatically. It
creates a new repository and fails rather than connecting if a repository is
already present. Never delete the bucket or rerun initialization as a way to
repair a connection problem.

Then create and validate the first generation:

```console
sudo systemctl start kopia-backup.service
sudo systemctl status \
  audiobookshelf-backup.service homebox-backup.service \
  jellyfin-backup.service paperless-exporter.service \
  invoiceshelf-backup.service kopia-backup.service
sudo journalctl --unit kopia-backup.service --since today
systemctl list-timers kopia-backup.timer kopia-verify.timer
```

`kopia-backup.service` first requires the Audiobookshelf, Homebox, Jellyfin,
Paperless, and InvoiceShelf artifact producers. A failure in any producer
therefore prevents an off-host generation from being reported as successful.
The standalone producer timers are disabled so Kopia controls the coherent
generation boundary.

## Verification

Every snapshot receives Kopia's structural verification. A weekly job also
downloads, decrypts, decompresses, and verifies a five-percent sample of files:

```console
sudo systemctl start kopia-verify.service
sudo journalctl --unit kopia-verify.service --since today
```

This detects repository corruption but is not equivalent to an application
restore. Perform and document periodic restores on separate storage.

## Recovery

On a replacement host, deploy the NixOS configuration and restore the SOPS age
identity first. The three Kopia secrets are sufficient to reconnect to the
repository; do not depend on state from `/var/cache/kopia` or `/run/kopia`.

List the available generations through a temporary, read-only Kopia connection:

```console
sudo list-kopia-snapshots
```

Each entry includes a root object ID beginning with `k`. Restore that root into
a new path beneath the dedicated restore-test boundary:

```console
sudo restore-kopia-snapshot \
  kSNAPSHOT_ROOT_ID \
  /srv/restore-tests/kopia-YYYYMMDD
```

The helper refuses existing targets and paths outside `/srv/restore-tests`. It
connects to the repository read-only, uses ephemeral configuration and cache
directories, and restores files atomically. It never writes into the live
`/srv/backups` staging tree.

Validate the recovered Jellyfin artifact without changing the running service:

```console
sudo validate-service-jellyfin-backup \
  /srv/restore-tests/kopia-YYYYMMDD/services/jellyfin/jellyfin-backup-TIMESTAMP.zip
```

This repeats the same ZIP, manifest, database-history, configuration, and
backup-option checks used when the archive was created. A successful validation
proves the artifact survived upload, encryption, remote storage, download,
decryption, and restoration.

Validate a recovered Paperless export without changing the running service:

```console
sudo validate-service-paperless-backup \
  /srv/restore-tests/kopia-YYYYMMDD/services/paperless
cat /srv/restore-tests/kopia-YYYYMMDD/services/paperless/metadata.json
```

The export must contain a structurally valid Django manifest and metadata for
the expected Paperless version. Application-level import must target an empty,
matching-version Paperless installation; never import it over the live
database.

Validate a recovered InvoiceShelf artifact without changing the running
service:

```console
sudo validate-service-invoiceshelf-backup \
  /srv/restore-tests/kopia-YYYYMMDD/services/invoiceshelf
cat /srv/restore-tests/kopia-YYYYMMDD/services/invoiceshelf/metadata.json
```

The validator checks the compressed MariaDB dump, storage archive paths, and
pinned application/database image identities. Applying the database dump and
storage archive is intentionally deferred until an isolated restore procedure
has been exercised after the empty deployment.

Only during disaster recovery or an isolated application-level restore drill
should the validated artifact be applied to Jellyfin:

```console
sudo restore-service-jellyfin \
  /srv/restore-tests/kopia-YYYYMMDD/services/jellyfin/jellyfin-backup-TIMESTAMP.zip
```

Do not restore staging files directly over live application state. The native
restore command validates the archive and controls service shutdown and startup.
