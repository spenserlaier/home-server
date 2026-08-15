# InvoiceShelf

InvoiceShelf 2.4.2 is declared privately at:

```text
https://invoices.home.hyrax.fyi
```

The application and MariaDB 10.11.14 run as Podman containers on a dedicated
private network. Both amd64 image manifests are pinned by digest. Caddy is the
only HTTP entry point; the application publishes container port 8080 only as
`127.0.0.1:8091` on the host.

InvoiceShelf 2.x is AGPL-3.0 and is in upstream feature freeze. Upstream has
committed security maintenance for 2.x through September 1, 2027. Version 3 is
still prerelease and is not a deployment target.

## Persistent state

```text
/srv/invoiceshelf/database  MariaDB data directory
/srv/invoiceshelf/storage   Laravel application files and generated documents
/srv/invoiceshelf/modules   installed InvoiceShelf modules
```

These bind mounts are the only application state retained across container
recreation. Container layers are disposable. Do not copy source code, caches,
or generated frontend bundles from the old Invoice Ninja installation into
these paths. The application image runs as numeric uid/gid 82, so the module
declaratively assigns both `storage` and `modules` to `82:82`; the database
container manages ownership of its own data directory. The module also creates
`storage/app/templates/pdf`, which InvoiceShelf requires while caching views
but its container entrypoint does not create on a fresh bind mount.

The upstream entrypoint initializes `storage/framework`, `storage/logs`, and
`bootstrap/cache` as `0755`, while the setup wizard requires `0775`. A
declarative `ExecStartPost` corrects all three after every container start;
`bootstrap/cache` lives in the disposable container layer, so a one-time host
permission change would not be sufficient.

## Secrets

Add the following values to `secrets/homeserver.yaml` using the workflow in
[secrets.md](./secrets.md):

```yaml
invoiceshelf:
  app_key: base64:GENERATED_LARAVEL_KEY
  database_password: GENERATED_DATABASE_PASSWORD
  database_root_password: GENERATED_ROOT_PASSWORD
```

Generate independent random database passwords and a Laravel-compatible key on
a trusted machine. One suitable key command is:

```console
openssl rand -base64 32 | sed 's/^/base64:/'
```

The stored `app_key` must include the literal `base64:` prefix and should be 51
characters long. Do not wrap quote characters into the secret value.
Database passwords should be the raw base64 output from `openssl rand -base64
32`, without a `base64:` prefix or surrounding quote characters. This alphabet
is safe for Podman's environment-file parser.

Do not reuse the Invoice Ninja `APP_KEY`: InvoiceShelf is a different
application and its migrated records will be transformed rather than restored
directly into its database.

## DNS and first deployment

Before activation, resolve `invoices.home.hyrax.fyi` to the homeserver's LAN
address through private DNS or a temporary hosts-file entry. Then build and
activate normally.

Inspect startup without printing container environment variables:

```console
sudo systemctl status \
  invoiceshelf-network.service \
  podman-invoiceshelf-database.service \
  podman-invoiceshelf.service
sudo journalctl --unit podman-invoiceshelf-database.service --since today
sudo journalctl --unit podman-invoiceshelf.service --since today
curl --fail --head https://invoices.home.hyrax.fyi
```

Complete InvoiceShelf's installation wizard with a temporary test company and
test data. The declared database connection is already supplied to the
container; do not create a second database or switch database engines in the
wizard.

Outbound email is deliberately deferred. The container declares Laravel's
`log` mail transport under both the legacy `MAIL_DRIVER` and current
`MAIL_MAILER` names, with `InvoiceShelf <noreply@invoices.home.hyrax.fyi>` as a
syntactically valid non-delivery sender. The setup wizard does not offer `log`;
select `mail` there only to satisfy its allow-list and enter the declared sender
name/address. The container environment takes precedence over the wizard's
`.env` value after the declarative configuration is activated. Messages are not
delivered; do not use the application's send action until a real mail provider
has been configured and tested.

## Empty-deployment acceptance

Before writing migration tooling, verify:

1. Login and company branding work.
2. A customer, draft invoice, finalized invoice, and payment can be created.
3. Invoice PDF generation works and contains the intended branding.
4. The scheduler runs in the official container without errors.
5. State survives a NixOS rebuild and reboot.
6. The backup producer succeeds and its recovered artifacts validate.

## Backup contract

InvoiceShelf has no stronger native export contract, so the producer briefly
stops the web container, creates a single-transaction MariaDB dump, archives
both persistent application trees, validates the result, and restarts the web
container. MariaDB remains running during the dump.

```text
/srv/backups/services/invoiceshelf/
├── database.sql.gz
├── storage.tar.zst
└── metadata.json
```

Run and inspect it manually:

```console
sudo systemctl start invoiceshelf-backup.service
sudo systemctl status invoiceshelf-backup.service
sudo journalctl --unit invoiceshelf-backup.service --since today
sudo validate-service-invoiceshelf-backup \
  /srv/backups/services/invoiceshelf
```

`kopia-backup.service` requires this producer alongside Jellyfin and Paperless,
so an invalid InvoiceShelf artifact prevents the coherent off-host generation
from succeeding.

## Migration boundary

The existing Invoice Ninja 5.11.43 instance remains authoritative until a
separate migration has been validated. Its source database is MariaDB 10.11.14
(`utf8mb4_unicode_ci`, 74 InnoDB tables) with approximately 5.8 MiB of data and
approximately 3.7 MiB under `public/storage`.

Migration will transform customers, invoices, line items, payments, statuses,
and any required documents into InvoiceShelf records. It will not restore the
Invoice Ninja database into InvoiceShelf or reuse Invoice Ninja's Laravel key.
Keep the source instance intact until record counts, invoice totals, PDFs, and
payment statuses agree.
