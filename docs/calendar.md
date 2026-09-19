# Household calendar

Radicale provides a shared **Family** calendar at
`https://calendar.home.hyrax.fyi`. All devices use the `household` login.
This is an additional calendar account, independent of Apple IDs and Google
accounts. Everyone using it can create, edit, and delete events. Revoking the
shared password requires updating every device. Use a distinct password from
Paperless and other household services.

The browser interface manages calendars and imports/exports; use a calendar
app to view and edit events. The initial Family calendar is created only when
the storage has no collection-root. Rebuilds preserve existing calendars.

## Credentials

The generated password is encrypted in `secrets/radicale.yaml` for the same
recipients as the other repository secrets. Retrieve it privately with SOPS
and save it in the household password manager. Do not paste it into logs or
commit it. See [secrets.md](secrets.md) for SOPS access and rotation.

On the server, SOPS delivers the password to a root-only secret file. systemd
passes it to Radicale's startup through LoadCredential. Startup creates a bcrypt
password file under `/run/radicale` without placing passwords or hashes in the
Nix store. Rotating the SOPS secret restarts Radicale and rebuilds that file.

## Apple devices

On home Wi-Fi, add a CalDAV account in Calendar account settings:

- Server: `calendar.home.hyrax.fyi`
- Username: `household`
- Password: the Radicale household password
- SSL: enabled, port 443
- Description: `Household`

If manual account URL entry is needed, use
`https://calendar.home.hyrax.fyi/household/`.
Select **Family** in Calendar. On iPhone/iPad, configure a periodic Fetch
schedule (for example, 15 minutes where offered). Apple's Automatically setting
can defer fetching until charging on Wi-Fi. On Mac, configure the account's
refresh interval in Calendar settings.

## Android devices

Install DAVx5, add an account with URL
`https://calendar.home.hyrax.fyi/`, and enter the household credentials.
Select **Family** under CalDAV and synchronize once. Grant calendar permissions,
allow background activity, exempt DAVx5 from battery optimization, and leave
Android automatic account synchronization enabled. Choose a periodic sync
interval, such as 15 minutes.

Use a calendar app that reads Android's calendar storage. Google Calendar on
Android can display this calendar after enabling its visibility; this does not
host it in Google's calendar service. DAVx5 is the sync adapter, not the event
editor. Wi-Fi-only/SSID restrictions are optional; an SSID restriction requires
additional location permission. Server access is enforced by the LAN firewall.

## Everyday behavior and pilot acceptance

Save shared events to **Family**, not an existing personal calendar. Previously
synchronized events remain available away from home. Changes exchange when the
server is reachable and the client synchronizes; arrival home does not guarantee
an immediate update. Connection errors away from home can occur. Two people
editing the same event offline can conflict.

Before relying on the calendar, verify on one Apple and one Android device:

1. Family appears during setup and a new event syncs in each direction.
2. Edits and deletion sync in each direction.
3. A recurring event, one edited occurrence, an all-day event, and a reminder
   behave correctly. Check reminder behavior on each device separately.
4. Leave home Wi-Fi, view and edit an event, then reconnect. Confirm automatic
   catch-up without manually opening DAVx5. Measure the observed delay.
5. Reboot both devices and confirm background sync still works.

## Server configuration and verification

`modules/services/radicale.nix` uses the pinned NixOS Radicale package (initially
3.7.4). Caddy proxies HTTPS to `127.0.0.1:5232`, and redirects the CalDAV
well-known path to the service root. Pi-hole supplies private DNS. No new public
ports or router forwarding are needed. Devices must use the home DNS resolver;
private DNS/VPN overrides can interfere with discovery.

```console
sudo systemctl status radicale
curl --user household --request PROPFIND --header 'Depth: 1' \
  https://calendar.home.hyrax.fyi/household/
```

curl prompts for the password; expect HTTP 207 and the Family collection.
Anonymous DAV requests and incorrect credentials must fail. Confirm port 5232
listens only on loopback. Service and backup failures feed existing monitoring.

## Persistence, backup, and restoration

| Path | Owner/mode | Purpose |
| --- | --- | --- |
| `/srv/radicale` | radicale:radicale 0750 | Service working directory |
| `/srv/radicale/collections` | radicale:radicale 0700 | Critical calendar data and metadata; disposable caches |
| `/run/radicale` | radicale:radicale 0700 | Reconstructed authentication file |
| `/srv/backups/services/radicale` | root:homelab-backup 0750 | Consistent calendar archives |

Kopia runs `radicale-backup.service` before each generation. The producer takes
Radicale's exclusive storage lock, archives collection-root including metadata,
excludes disposable caches and temporary files, verifies the archive, then
publishes it atomically. It waits up to 120 seconds for the lock and retains
local archives for seven days. Kopia supplies off-host retention. Credentials
are recovered from SOPS rather than calendar archives.

```console
sudo systemctl start radicale-backup
sudo systemctl start kopia-backup
```

For recovery, first use [backup-and-restore.md](backup-and-restore.md) to restore
a Kopia generation into a new isolated directory under `/srv/restore-tests`.
List the selected `radicale-state-*.tar.gz` archive and extract into an empty
isolated directory. Check that it contains `collection-root/household/family`,
`.Radicale.props`, and expected event files. Run Radicale's `--verify-storage`
against the isolated collection store before restoring live service.

For live recovery, stop Radicale, preserve the existing collections directory
under a separate recovery path, create an empty collections directory, and
extract the selected archive there. Set the restored tree's ownership to
radicale:radicale, directories to 0700 and files to 0600. This is a one-time
restore operation, not a routine recursive ownership change. Start Radicale and
verify the restored events using a fresh client profile. Existing clients may
hold pending edits; reconcile them before allowing synchronization to overwrite
recovered data. A restored store reconstructs its lock and caches.

## References

- [Radicale configuration, storage locking and clients](https://radicale.org/v3.html)
- [DAVx5 settings](https://manual.davx5.com/settings.html)
- [Apple Calendar settings](https://support.apple.com/guide/iphone/change-calendar-settings-iphc37be2016/ios)
