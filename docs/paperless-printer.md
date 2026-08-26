# Paperless logical printers

The home server exposes two LAN-only, driverless IPP destinations:

```text
Save to Paperless            -> Paperless consumption directory
Print and Save to Paperless  -> Epson ET-4950 and Paperless independently
```

The Epson ET-4950 has a DHCP reservation at `192.168.4.21`. CUPS keeps its
driverless downstream queue private on the server; household clients use the
printer's own AirPrint service for ordinary printing and the two logical
printers for archival workflows.

## Delivery model

Each accepted PDF is validated, limited to 100 MiB, and durably staged below:

```text
/srv/paperless-printer/jobs
```

The IPP request succeeds only after the job directory is atomically published.
A timer dispatches the archive and physical branches separately every 15
seconds. Paperless receives a `0600`, `paperless:paperless` PDF through an
atomic rename into `/srv/paperless/consume`. Physical jobs are submitted to the
`Epson_ET_4950` CUPS queue.

An interrupted dispatch retains a `*.dispatching` marker for manual review.
The service intentionally does not retry an ambiguous operation because doing
so could duplicate a Paperless document or physical print. Completed transient
payloads are removed after seven days.

The archived PDF represents the rendered document. Copies, duplex, media, and
color selections are recorded as job metadata and supported selections are
forwarded to the physical queue; multiple requested copies do not duplicate
pages in the Paperless document.

## Network access

The logical printers advertise themselves with DNS-SD/mDNS and listen on:

```text
ipp://homeserver.home.arpa:8631/ipp/print  Save to Paperless
ipp://homeserver.home.arpa:8632/ipp/print  Print and Save to Paperless
```

TCP 8631 and 8632 and UDP 5353 are accepted only from the trusted
`192.168.4.0/22` LAN. The queues do not require credentials, so membership of
that LAN is the authorization boundary.

## Deployment and acceptance

Before rebuilding, confirm that the printer responds at its reserved address:

```console
curl --fail --head http://192.168.4.21
```

Deploy with the usual test activation first. Then verify the units and queues:

```console
systemctl status cups paperless-printer-configure.service \
  paperless-save-printer.service paperless-print-save-printer.service \
  paperless-printer-dispatch.timer
lpstat -t
lpoptions -p Epson_ET_4950 -l
ss -lntup | grep -E ':(631|5353|8631|8632)\b'
```

From a household client, allow discovery a few seconds to populate the printer
list. If discovery is unavailable, add the applicable IPP URL above manually.

Acceptance should use disposable one-page PDFs in this order:

1. Send to **Save to Paperless** and confirm it appears once in Paperless and
   no sheet prints.
2. Send to **Print and Save to Paperless** and confirm exactly one Paperless
   document and one physical job.
3. Turn off the Epson, submit another print-and-save job, and confirm Paperless
   still ingests it while CUPS retains the physical job for retry.
4. Stop the Paperless consumer, submit another print-and-save job, and confirm
   the physical job prints while the PDF waits in `/srv/paperless/consume`.
5. Exercise simplex/duplex, monochrome/color, multiple copies, and Letter media.

Inspect failures and queued state with:

```console
journalctl --unit paperless-printer-configure.service \
  --unit paperless-save-printer.service \
  --unit paperless-print-save-printer.service \
  --unit paperless-printer-dispatch.service --since today
find /srv/paperless-printer/jobs -mindepth 1 -maxdepth 2 -ls
```

Do not delete or rename a `*.dispatching` marker until the corresponding CUPS
queue or Paperless library has been checked for the job. After determining that
delivery did not occur, remove only that branch's marker; its `*.pending` marker
will cause a retry on the next timer run.
