# Homebox

Homebox is available through Caddy at:

```text
https://homebox.home.hyrax.fyi
```

The native NixOS module runs the pinned Homebox 0.25.0 package. Port 7745 is
bound only to the loopback interface and is not opened in the host firewall.
Caddy terminates HTTPS and proxies HTTP and WebSocket traffic on the same host.

## Persistent state

Homebox stores its SQLite database, uploaded images, documents, and generated
assets beneath:

```text
/srv/homebox/data
```

Temporary upload files use `/srv/homebox/tmp` and are not part of the backup
contract. SQLite remains on the local Btrfs-backed `/srv` subvolume rather than
a network filesystem.

## Owner bootstrap

The encrypted secrets file contains a distinct generated password:

```yaml
homebox:
  admin_password: replace-with-a-generated-password
```

On the first start, `homebox-initialize.service` runs Homebox temporarily on
loopback port 7746, enables registration only on that private listener, and
creates the initial owner:

```text
Name:  Home Admin
Email: admin@home.hyrax.fyi
```

The normal service starts on port 7745 with registration disabled. Caddy waits
for initialization, so neither the temporary listener nor open registration is
available through the household hostname. If the database already contains a
user, the initializer makes no changes. Changing the SOPS value does not rotate
an existing password.

Retrieve the generated password on an authorized administrative machine:

```console
sops decrypt --extract '["homebox"]["admin_password"]' secrets/homeserver.yaml
```

Avoid leaving the value in shell history, terminal scrollback, or a plaintext
password file.

## First deployment

After rebuilding, verify initialization, the service, and the proxy:

```console
sudo systemctl status homebox-initialize homebox caddy
sudo journalctl --unit homebox-initialize --since today
curl --fail https://homebox.home.hyrax.fyi/api/v1/status
```

Sign in with `admin@home.hyrax.fyi` and the SOPS password. Confirm that the
registration screen is unavailable, then create a small test location and item
with an image attachment.

## Backup contract

Before each Kopia generation, `homebox-backup.service` briefly stops Homebox
and archives the complete `data` directory to:

```text
/srv/backups/services/homebox
```

Stopping the service makes the SQLite database, WAL, and uploaded attachments
one coherent artifact. Local archives older than seven days are removed after
a successful new archive; Kopia applies longer off-host retention.

Exercise the backup after creating test data:

```console
sudo systemctl start homebox-backup.service
sudo systemctl status homebox-backup.service homebox.service
sudo tar -tzf /srv/backups/services/homebox/homebox-state-*.tar.gz
```

## Restore

Restore is deliberately manual until a full recovery drill has been completed:

1. Rebuild a replacement host so the service user and `/srv` paths exist.
2. Stop `homebox.service`.
3. Extract one archive into an empty `/srv/homebox`.
4. Restore ownership to `homebox:homebox`.
5. Start the service and verify login, locations, items, and attachments.

The bootstrap unit preserves credentials from a restored database. Homebox
0.25.0 performs forward-only database migrations, so restore the pre-upgrade
archive if an application upgrade must be rolled back.
