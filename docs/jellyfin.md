# Jellyfin

Jellyfin is available through Caddy at:

```text
https://jellyfin.home.hyrax.fyi
```

Port 8096 is not opened in the host firewall. Caddy is the supported client
entry point and proxies to Jellyfin on the same host. Until Pi-hole provides
private DNS, add this name beside the Caddy health-check name in the client
hosts file:

```text
HOMESERVER_LAN_ADDRESS caddy.home.hyrax.fyi jellyfin.home.hyrax.fyi
```

## Persistent state

The service owns these paths:

```text
/srv/jellyfin/data    database, metadata, plugins, and generated assets
/srv/jellyfin/config  server and encoding configuration
/srv/jellyfin/cache   reconstructable cache and transcode files
```

`data` and `config` are valuable state and must be included in backups. `cache`
is disposable and should be excluded. Logs remain in `/var/log/jellyfin` and
are not application state.

Media is kept separately:

```text
/srv/media/movies
/srv/media/tv
```

These directories are `root:media`. Members of `media`, including Jellyfin and
the administrator, can read and traverse them but cannot modify their contents
without elevated privileges. This prevents Jellyfin from deleting source media.

## First deployment

After rebuilding, verify the service and proxy:

```console
sudo systemctl status jellyfin caddy
curl --fail https://jellyfin.home.hyrax.fyi/health
```

Open `https://jellyfin.home.hyrax.fyi` and complete Jellyfin's initial setup
wizard. Add libraries using `/srv/media/movies` and `/srv/media/tv`. Do not
enable Jellyfin's own HTTPS listener or expose its ports; Caddy owns TLS.

The wizard creates mutable application configuration beneath `/srv/jellyfin`.
That state is deliberately backed up and restored rather than encoded in Nix,
because Jellyfin does not provide a complete stable declarative interface for
users, libraries, and plugins.

## Hardware transcoding

The GMKtec M5 Ultra uses a Ryzen 7 7730U with AMD Vega graphics. Nix configures
Jellyfin to use VA-API through `/dev/dri/renderD128` for supported H.264, HEVC,
MPEG-2, VC-1, VP8, and VP9 workloads. AV1 is excluded because this GPU
generation does not provide AV1 hardware decoding. The NixOS graphics stack is
enabled explicitly because this headless host has no desktop module that would
otherwise populate `/run/opengl-driver` with Mesa's `radeonsi` VA-API driver.

Confirm the render device and VA-API capabilities on the server:

```console
ls -l /dev/dri/renderD128
sudo -u jellyfin env XDG_CACHE_HOME=/srv/jellyfin/cache \
  vainfo --display drm --device /dev/dri/renderD128
```

After playing media that requires transcoding, verify that the playback info
reports hardware transcoding and inspect the Jellyfin log for `vaapi`.

## Rebuild and reboot verification

After completing the wizard and adding a small test library:

1. Record the server name, administrator login, and library item count.
2. Run another `nixos-rebuild switch` and reboot.
3. Confirm the HTTPS endpoint, login, library, and playback still work.
4. Confirm `/srv/jellyfin` is backed by the dedicated `/srv` subvolume:

```console
findmnt --target /srv/jellyfin/data
sudo stat --format '%U:%G %a %n' /srv/jellyfin/{data,config,cache}
```

## Native backup contract

Jellyfin 10.11 can create a database-consistent archive while the service
remains online. A systemd timer invokes that supported API daily around 04:15,
with up to fifteen minutes of randomized delay. Jellyfin recommends scheduling
live backups during low activity and outside library scans.

The archive contains:

- Database, including users, API keys, libraries, and playback state.
- Server configuration and scheduled-task configuration.
- Metadata and artwork.
- Extracted and downloaded subtitles.

Trickplay data and cache files are excluded because they are reconstructable.
Media files are outside this contract.

Jellyfin first creates the archive below its native backup directory. The job
then verifies the ZIP, manifest, migration history, configuration entries, and
requested content flags before moving it to:

```text
/srv/backups/services/jellyfin
```

Validated archives remain there for seven days. A later whole-host Kopia job
will snapshot this staging directory as part of one coherent backup generation
and apply long-term off-host retention.

### API-key bootstrap

In Jellyfin, open **Dashboard → Advanced → API Keys**, create a key named
`nixos-backup`, and add it to `secrets/homeserver.yaml`:

```yaml
jellyfin:
  api_key: replace-me
```

This one-time key authorizes the local backup API. It is decrypted to a `0400`
file owned by Jellyfin and does not enter the Nix store or command-line
arguments. Keep the key stable: native archives contain Jellyfin's API-key
database, so a restore returns keys to their state at archive creation time.

After deploying the secret declaration, exercise the contract immediately:

```console
sudo systemctl start jellyfin-backup.service
sudo systemctl status jellyfin-backup.service
sudo journalctl --unit jellyfin-backup.service --since today
sudo -u jellyfin ls -lh /srv/backups/services/jellyfin
systemctl list-timers jellyfin-backup.timer
```

The service must report a validated archive. Failure is noisy: an API error,
malformed response, unexpected path, incomplete archive, or failed integrity
check causes the systemd unit to fail rather than presenting the output as a
usable backup.

### Restore interface

The per-service recovery primitive is intentionally manual and destructive:

```console
sudo restore-service-jellyfin \
  /srv/backups/services/jellyfin/jellyfin-backup-TIMESTAMP.zip
```

It verifies the archive, asks once for confirmation, ensures a replacement
instance has initialized its database schema, stops Jellyfin, invokes
Jellyfin's supported `--restore-archive` operation with the declared `/srv`
paths, restarts the service, and verifies that systemd reports it active.

The initialization step works around a Jellyfin 10.11 limitation in which CLI
restore fails against a completely uninitialized database. This command will
later be registered as one step in `restore-from-backups`; it is not intended
to make whole-host recovery service-by-service.
