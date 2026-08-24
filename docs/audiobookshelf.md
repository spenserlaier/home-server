# Audiobookshelf

Audiobookshelf is available through Caddy at:

```text
https://audiobookshelf.home.hyrax.fyi
```

Port 8000 is bound only to the loopback interface and is not opened in the
host firewall. Caddy terminates HTTPS and proxies Audiobookshelf's HTTP and
WebSocket traffic on the same host.

## Persistent state and media

Audiobookshelf owns its application state beneath:

```text
/srv/audiobookshelf/config
/srv/audiobookshelf/metadata
```

The SQLite database and migrations are in `config`. Covers, author images,
logs, caches, and application-created backups are in `metadata`.

Audiobook source files are kept separately at:

```text
/srv/media/audiobooks
```

The directory is `root:media` with mode `2770`. Its setgid bit makes files and
directories copied by `spenser-admin` inherit the `media` group, allowing
direct `scp` or `rsync` transfers into the library. Audiobookshelf can read the
source files, but the service's `ReadOnlyPaths` sandbox prevents it from
modifying them. Its upload, metadata-embedding, and media-conversion features
therefore remain unavailable; add and organize books through an administrative
shell instead.

Use one directory per book. A useful starting layout is
`Author/Series/Book` or `Author/Book`.

## First deployment

Before rebuilding, add a distinct generated password to the encrypted secrets
file:

```yaml
audiobookshelf:
  admin_password: replace-with-a-generated-password
```

On first start, `audiobookshelf-initialize.service` waits for the loopback
listener and creates the root account named `admin`. Caddy waits for this unit,
so the uninitialized setup endpoint is not exposed through the household
hostname. Later starts detect the initialized database and leave the account
unchanged; changing the SOPS value does not rotate an existing password.

After rebuilding, verify the bootstrap, service, and proxy:

```console
sudo systemctl status audiobookshelf-initialize audiobookshelf caddy
sudo journalctl --unit audiobookshelf-initialize --since today
curl --fail --head https://audiobookshelf.home.hyrax.fyi
```

Open `https://audiobookshelf.home.hyrax.fyi`, sign in as `admin` with the SOPS
password, and add an audiobook library rooted at `/srv/media/audiobooks`. The
generated password can be retrieved on an authorized administrative machine:

```console
sops decrypt --extract '["audiobookshelf"]["admin_password"]' secrets/homeserver.yaml
```

Avoid leaving the value in shell history, terminal scrollback, or a plaintext
password file.

Do not enable a separate HTTPS listener or expose port 8000. Caddy is the
supported client entry point.

## Backup contract

Before each Kopia generation, `audiobookshelf-backup.service` briefly stops
Audiobookshelf and creates a consistent archive at:

```text
/srv/backups/services/audiobookshelf
```

The archive contains `config` and `metadata`, excluding reconstructable caches
and logs. Audiobook media is intentionally outside this backup contract. Local
archives older than seven days are removed after a successful new archive;
Kopia applies the longer off-host retention policy.

Exercise the backup after initial setup:

```console
sudo systemctl start audiobookshelf-backup.service
sudo systemctl status audiobookshelf-backup.service audiobookshelf.service
sudo tar -tzf /srv/backups/services/audiobookshelf/audiobookshelf-state-*.tar.gz
```

The service restarts Audiobookshelf if it was active before the backup, even
when archive creation fails.

## Restore

Restore is deliberately manual until the application has accumulated enough
real state for a full recovery drill:

1. Rebuild a replacement host so the service user and `/srv` paths exist.
2. Stop `audiobookshelf.service`.
3. Extract one archive into an empty `/srv/audiobookshelf`.
4. Restore ownership to `audiobookshelf:audiobookshelf`.
5. Start the service and verify accounts, libraries, covers, and listening
   progress.

Do not restore an archive over a running instance. Audiobookshelf's SQLite
database must remain local to this machine rather than on a network filesystem.
After restoring an initialized database, the bootstrap unit preserves the
restored root credentials rather than applying the current SOPS value.
