# Epson maintenance printing

The home server checks the ET-4950's own IPP completion history, including jobs
sent directly over AirPrint. It submits a one-page color exercise PDF through
the existing private `Epson_ET_4950` CUPS queue when either:

- no successful physical print has been observed for seven days; or
- fourteen days have elapsed since the last confirmed dedicated exercise page.

These are configurable starting intervals, not an Epson maintenance guarantee.
The maximum interval ensures ordinary monochrome jobs, or jobs merely submitted
in color mode, cannot postpone a dedicated color page forever. The page contains
small black, cyan, magenta, and yellow bands and fine lines across the printable
width. Driver color management can mix inks; this is an exercise page, not the
printer's firmware nozzle-check pattern. Inspect it for gaps or streaks and use
Epson's nozzle-check/cleaning procedure if print quality declines. The service
does not run cleaning or flushing cycles.

## Configuration

`homelab.printerMaintenance.enable` is enabled on the homeserver. Defaults:

```nix
homelab.printerMaintenance = {
  enable = true;
  idleDays = 7;
  maximumDays = 14;
  schedule = "*-*-* 09..18:00:00 America/New_York";
};
```

Checks run hourly during daytime hours. The timer does not catch up at boot,
so booting at night does not trigger a maintenance print. An unavailable,
busy, or attention-needed printer is deferred until a later check. Pending
ordinary jobs in the server's CUPS queue also defer maintenance. A check can
race with a client submitting another job; IPP cannot reserve an idle printer.
Once accepted by CUPS, a queued page can finish outside the check window if the
printer becomes available later; the schedule controls submission checks.

The service submits one Letter, plain-paper, normal-quality, single-sided color
page. It bypasses the Paperless logical printers, so exercise pages never enter
the document archive or interact with its filename/title handling.

## History and delivery

The printer was verified to support `Get-Jobs` for completed jobs, with job state,
completion time, impression count, and selected color mode. Its retention is
limited: successive observations returned one and then two recent jobs, rather
than a permanent audit trail. Copies, fax output, USB jobs, and jobs that vanish
between checks are not guaranteed to appear in this history. No per-nozzle
activity data is assumed. The server preserves the newest observed successful
completion across restarts and printer history expiration. Canceled, aborted,
zero-impression, and completed-with-errors jobs do not reset the idle clock.
If the completion date is absent, a valid printer uptime difference supplies
an approximate completion time. Implausible future dates are ignored.

On first activation, usable old printer history can make an idle page due
immediately. If no usable history exists, the service starts a seven-day grace
period. The fourteen-day dedicated-page clock starts at first observation.

Before submission, the service durably records a unique job title. Until that
job is resolved, it cannot submit another maintenance page. It polls printer
history for up to two minutes after submission, and reconciles outstanding jobs
on later checks. Only a matching successful completion reported by the physical
printer advances the dedicated-page clock; CUPS acceptance/completion alone
does not. CUPS retains job metadata for up to thirty days, subject to its job
count limit, without retaining completed document payloads.

A canceled or aborted CUPS job releases the outstanding attempt, with a minimum
24-hour interval between attempts. A missing job, expired history, or a CUPS
completion without matching printer confirmation requires review instead of an
automatic retry. Service failures participate in the existing operational
monitoring. An offline printer is logged as a skipped check.

## Persistent state

`/srv/printer-maintenance` is owned by `printer-maintenance:printer-maintenance`
with mode `0700`. Its `state.json` holds initialization/completion/attempt times
and any outstanding job token/CUPS ID. The service also writes a lock file and
the most recently generated `exercise.pdf`. No other service shares these files.
The PDF and lock are disposable; the JSON is operational bookkeeping, not
critical application data. It is excluded from Kopia's application-consistent
backup artifacts. Keep it across routine rebuilds. Losing it resets the timing
baseline and removes duplicate-prevention knowledge, so check both queues before
reinitializing state. No database export or restore procedure is required.

## Verification and recovery

Before activation, run the isolated checks (no network or printing):

```console
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
nix flake check --no-build --all-systems
```

After deploying the configuration, inspect the decision without submitting or
changing bookkeeping:

```console
sudo -u printer-maintenance check-printer-maintenance --dry-run
systemctl status printer-maintenance.timer
systemctl list-timers printer-maintenance.timer
journalctl -u printer-maintenance.service --since today
sudo cat /srv/printer-maintenance/state.json
lpstat -W all -o Epson_ET_4950
```

Inspect the PDF produced by the first due run and confirm that exactly one sheet
prints and the log reports physical completion. If the printer does not preserve
the unique job title through CUPS, completion will remain unconfirmed; establish
that behavior before relying on automatic delivery reconciliation.

For an ambiguous attempt, stop both `printer-maintenance.timer` and
`printer-maintenance.service`, then inspect `state.json`, CUPS job
history, printer history, and physical output. Cancel any still-queued copy
before clearing the outstanding token. After establishing the result, atomically
edit `state.json`: clear `pending`; if the page did print, set `last_maintenance`
and `last_success` to its confirmed Unix completion time. Preserve `last_attempt`
to retain the retry cooldown. Then restart the timer. Do not delete the entire
state file as a routine retry mechanism.
