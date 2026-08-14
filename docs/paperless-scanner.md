# Brother ADS-4300N ingestion

The scanner uploads PDFs over SFTP into an isolated staging directory. A
timer checks that each upload is closed and has not changed for at least 30
seconds, then atomically renames it into Paperless's consumption directory.

```text
ADS-4300N -> /srv/paperless-scanner/inbox -> /srv/paperless/consume
```

The `paperless-scanner` account is confined to internal SFTP, has no shell or
forwarding facilities, and its authorized key is accepted only from the
scanner's reserved address, `192.168.4.38`.

The initial physical scan has completed this path successfully and its
handwritten content was searchable through Paperless OCR. Duplex behavior,
blank-page removal, a naturally scheduled backup, and a restored-document drill
remain deferred acceptance tests. The retained test document is the payload for
that later backup exercise.

## Scanner profile

Use these values in the Brother web interface:

```text
Profile Name: Paperless
Host Address: 192.168.4.22
Username: paperless-scanner
Authentication: Public Key
Client Key Pair: paperless-sftp
Store Directory: inbox
Port: 22
File Type: PDF
```

Import the homeserver's SSH host public key under **Network -> Security ->
Server Public Key**, then select that key in the SFTP profile. Obtain the key
from the homeserver rather than an administrator workstation:

```console
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
```

The public host key is safe to transfer. Compare its fingerprint before
importing it:

```console
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

## Verification

After activating the configuration, confirm the account, timer, and staging
permissions:

```console
getent passwd paperless-scanner
systemctl list-timers paperless-scanner-handoff.timer
sudo stat --format '%U:%G %a %n' \
  /srv/paperless-scanner /srv/paperless-scanner/inbox
```

Scan a disposable one-page document using the Paperless profile. The upload
may remain in the inbox for up to one minute while the quiet interval elapses.
Then inspect the handoff and Paperless consumer:

```console
sudo journalctl --unit paperless-scanner-handoff.service --since today
sudo find /srv/paperless-scanner/inbox -maxdepth 1 -type f -ls
sudo journalctl --unit paperless-consumer.service --since today
```

Successful handoff leaves the scanner inbox empty. Paperless should ingest the
PDF, remove it from `/srv/paperless/consume`, and display the document in the
web interface.
