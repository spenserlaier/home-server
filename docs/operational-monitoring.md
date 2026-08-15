# Operational monitoring

The safety slice deliberately uses systemd, smartd, the journal, and small local
checks rather than a separate monitoring stack. It detects backup producer and
verification failures, stale Kopia backups, high filesystem usage, and SMART
warnings.

## Alert behavior

Active alerts are durable files beneath `/var/lib/homelab-alerts`. Every new or
updated alert is also written to the journal at error priority, broadcast to
currently logged-in terminals, and delivered to the private ntfy service.
Successful checks clear their corresponding failure alert.

List active alerts after login:

```console
sudo list-homelab-alerts
sudo journalctl --identifier=homelab-alert --since today
```

`list-homelab-alerts` exits with status 1 when alerts exist. ntfy delivery is
best-effort: a push failure never suppresses the durable alert or changes the
result of the original service. The Android subscriber can reach ntfy only on
the LAN until NetBird is deployed.
After investigating a hardware warning that does not clear automatically,
acknowledge its exact key with `sudo clear-homelab-alert ALERT_KEY`.

## ntfy

The NixOS ntfy service listens only on `127.0.0.1:2586`; Caddy exposes it as the
private HTTPS endpoint `ntfy.home.hyrax.fyi`. Anonymous access is denied. An
idempotent bootstrap service reconciles two SOPS-managed accounts and their
single-topic permissions on every deployment:

* `homelab-monitoring` can publish but cannot subscribe.
* `spenser-phone` can subscribe but cannot publish.

The authentication database and short-lived message cache are reconstructable
local state beneath `/var/lib/ntfy-sh`; they are not part of disaster recovery.
Nix and SOPS recreate the accounts, passwords, and permissions.

Add `ntfy.home.hyrax.fyi` to private DNS with the other local service names.
Install the ntfy Android application, add `https://ntfy.home.hyrax.fyi` as a
server, authenticate as `spenser-phone`, and subscribe to `homeserver-alerts`.
Retrieve the generated subscriber password directly from SOPS when configuring
the phone; do not save a decrypted copy.

Exercise the complete local path:

```console
sudo systemctl start homelab-alert-test.service
sudo list-homelab-alerts
sudo clear-homelab-alert delivery-test
```

Confirm the push reaches the phone and that publishing or anonymous subscription
without credentials is rejected.

## Healthchecks.io

Hosted Healthchecks.io is the independent dead-man monitor. Nix declaratively
upserts two checks using stable slugs:

* `homeserver-heartbeat` expects a ping every five minutes with ten minutes of
  grace.
* `homeserver-kopia-backup` follows the declared Kopia systemd schedule with two
  hours of grace.

The reconciliation service uses the Healthchecks Management API and attaches all
existing project integrations. It writes the returned ping URLs to a private
local state file. The external checks, history, and email integration survive
loss of the home-server hardware; the local file is regenerated using the
SOPS-managed project API key.

One-time external setup:

1. Create a dedicated Healthchecks.io project for the home server.
2. Add and verify its email integration.
3. Create a project-scoped read-write API key.
4. Add it as `healthchecks/api_key` in `secrets/homeserver.yaml`.

The API key is required because the host creates and updates checks; a read-only
key cannot reconcile them. The repository never deletes external checks.

After deployment, inspect the two checks in Healthchecks.io and verify that the
email integration is assigned. Then run:

```console
sudo systemctl status healthchecks-reconcile.service
systemctl list-timers healthchecks-heartbeat.timer
sudo systemctl start healthchecks-heartbeat.service
sudo journalctl --unit healthchecks-heartbeat.service --since today
```

Kopia sends a best-effort `/start` signal before work, success after every
producer, snapshot, and verification step succeeds, and `/fail` through its
systemd failure hook. Healthchecks delivery problems never turn a usable backup
into a failed backup job. The required heartbeat does fail locally when it
cannot reach Healthchecks, producing a durable ntfy-visible alert while the
external heartbeat independently approaches its deadline.

## Checks

`homelab-disk-space-check.timer` runs daily and fails at 80% usage. All current
Btrfs subvolumes share the same physical filesystem, so checking `/srv` covers
the capacity pool used by `/`, `/nix`, `/srv`, and `/var/log`.

`homelab-backup-freshness-check.timer` runs daily and requires a successful
`kopia-backup.service` execution within the previous 36 hours. The first check
after deployment will alert until Kopia completes successfully; this is useful
confirmation that the success marker is connected to the real backup path.

smartd monitors autodetected storage devices. Device-health warnings use the
same durable alert path. The backup producers, Kopia backup, and weekly Kopia
verification also create alerts through systemd `OnFailure` hooks.

## Deployment verification

After switching the host configuration:

```console
systemctl list-timers \
  homelab-disk-space-check.timer \
  homelab-backup-freshness-check.timer \
  healthchecks-heartbeat.timer \
  kopia-backup.timer kopia-verify.timer
sudo systemctl status smartd.service ntfy-sh.service ntfy-bootstrap.service
sudo systemctl start homelab-disk-space-check.service
sudo systemctl start homelab-backup-freshness-check.service
sudo list-homelab-alerts
```

If the freshness check reports that no backup has been recorded, allow the next
natural Kopia timer run to establish the marker. Do not start a manual backup
merely to make the monitoring check green when the acceptance goal is to verify
natural scheduling.
