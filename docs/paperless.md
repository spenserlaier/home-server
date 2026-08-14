# Paperless-ngx

Paperless-ngx 2.20.15 is available privately at:

```text
https://paperless.home.hyrax.fyi
```

The initial slice uses the NixOS-native Paperless module with local PostgreSQL
and Redis. Scanner delivery and Samba are deliberately deferred until ordinary
web upload, OCR, export, and recovery have been verified.

## Persistent state

```text
/srv/paperless/data     search index and auxiliary application state
/srv/paperless/media    original documents, archives, and thumbnails
/srv/paperless/consume  private local consumption directory
/srv/postgresql         shared PostgreSQL cluster
```

Paperless owns its three application directories. PostgreSQL owns its cluster.
All are private and reside on the dedicated `/srv` subvolume. Redis and caches
are reconstructable and do not need separate persistence contracts.

The `admin` account password and stable `PAPERLESS_SECRET_KEY` are delivered by
SOPS. The secret key must remain stable across rebuilds and upgrades.

## Deploy and verify

Add this private DNS override before opening the application:

```text
HOMESERVER_LAN_ADDRESS paperless.home.hyrax.fyi
```

Build before activating:

```console
sudo nixos-rebuild build --flake .#homeserver
sudo nixos-rebuild switch --flake .#homeserver
```

Check the service group, database, HTTPS endpoint, and directory ownership:

```console
sudo systemctl status \
  postgresql redis-paperless paperless-scheduler paperless-task-queue \
  paperless-consumer paperless-web
curl --fail https://paperless.home.hyrax.fyi
sudo -u postgres psql --dbname paperless --command 'select current_database();'
sudo stat --format '%U:%G %a %n' \
  /srv/paperless/{data,media,consume} \
  /srv/postgresql
```

Sign in as `admin` with the SOPS-managed password. Upload a small test PDF and
confirm that consumption completes, text is searchable, and both the original
and archived document are available.

## Backup contract

Paperless's native document exporter is the authoritative application-consistent
artifact. It stops the Paperless web, consumer, scheduler, and worker services;
exports documents, thumbnails, settings, metadata, and database contents; then
restarts the application. Its incremental export lives at:

```text
/srv/backups/services/paperless
```

The standalone exporter timer is disabled. `kopia-backup.service` requires both
the Jellyfin and Paperless producers, so failure of either prevents a generation
from being reported as successful.

Run and inspect the export independently before the first combined generation:

```console
sudo systemctl start paperless-exporter.service
sudo systemctl status paperless-exporter.service
sudo journalctl --unit paperless-exporter.service --since today
sudo validate-service-paperless-backup /srv/backups/services/paperless
sudo find /srv/backups/services/paperless -maxdepth 2 -type f -ls
```

Then exercise the combined generation:

```console
sudo systemctl start kopia-backup.service
sudo journalctl \
  --unit jellyfin-backup.service \
  --unit paperless-exporter.service \
  --unit kopia-backup.service \
  --since today --no-pager --full
```

Paperless exports are version-sensitive because they contain an exact database
representation. Recovery should initially use the same Paperless version that
created the export. The eventual restore drill will import this tree into a new,
empty Paperless installation; it must never be imported over the live database.
