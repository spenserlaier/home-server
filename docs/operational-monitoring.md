# Operational monitoring

The safety slice deliberately uses systemd, smartd, the journal, and small local
checks rather than a separate monitoring stack. It detects backup producer and
verification failures, stale Kopia backups, high filesystem usage, and SMART
warnings.

## Alert behavior

Active alerts are durable files beneath `/var/lib/homelab-alerts`. Every new or
updated alert is also written to the journal at error priority and broadcast to
currently logged-in terminals. Successful checks clear their corresponding
failure alert.

List active alerts after login:

```console
sudo list-homelab-alerts
sudo journalctl --identifier=homelab-alert --since today
```

`list-homelab-alerts` exits with status 1 when alerts exist, so it can also be
used by a future push or email delivery hook. Local durable alerts are the
initial transport; external delivery remains intentionally undecided.
After investigating a hardware warning that does not clear automatically,
acknowledge its exact key with `sudo clear-homelab-alert ALERT_KEY`.

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
  kopia-backup.timer kopia-verify.timer
sudo systemctl status smartd.service
sudo systemctl start homelab-disk-space-check.service
sudo systemctl start homelab-backup-freshness-check.service
sudo list-homelab-alerts
```

If the freshness check reports that no backup has been recorded, allow the next
natural Kopia timer run to establish the marker. Do not start a manual backup
merely to make the monitoring check green when the acceptance goal is to verify
natural scheduling.
