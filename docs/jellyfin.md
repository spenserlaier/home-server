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
generation does not provide AV1 hardware decoding.

Confirm the render device and VA-API capabilities on the server:

```console
ls -l /dev/dri/renderD128
sudo -u jellyfin vainfo --display drm --device /dev/dri/renderD128
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
