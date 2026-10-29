# Persistent state conventions

`/srv` is the boundary for application data that must survive service
recreation and operating-system rebuilds. Disko mounts it as a dedicated Btrfs
subvolume, and `modules/base/persistent-state.nix` enforces its root ownership
and mode:

```text
root:root 0755 /srv
```

The separate subvolume prevents application state from being mixed into the
root subvolume. It does not isolate failures within the same physical disk, and
it is not a backup.

## Directory ownership

Do not create the entire proposed `/srv` tree in advance. Each service module
must create only the directories it uses, at the same time that it declares the
service account and group that own them.

Use these defaults unless a service has a documented reason to differ:

- Service-private state: `0750`, owned by the service user and group.
- Kopia UI restores: `/srv/kopia-ui/restores`, `0700`, owned by `kopia-ui`.
  This is a disposable inspection workspace, excluded from backups. Repository
  configuration is regenerated under `/run/kopia-ui`; cache and logs live under
  `/var/cache/kopia-ui` and can be rebuilt from B2.
- Secret-bearing directories: `0700`, owned by the consuming service user.
- Shared read-only data: `0750`, with a narrowly scoped shared group.
- Deliberate LAN-facing drop directories: isolate them from application state,
  constrain their service identity, and use a validated handoff rather than
  making an application consumption directory world-writable. The Brother
  scanner is chrooted to `/srv/paperless-scanner/inbox`; a root-owned service
  atomically moves completed files into Paperless.
- Logical printer jobs use `/srv/paperless-printer/jobs` as a private durable
  outbox. These payloads are transient and excluded from Kopia because only the
  application-consistent artifacts below `/srv/backups` are captured.
- Trilium owns `/srv/trilium` as `trilium:trilium`, mode `0750`. Its database
  contains notes, revisions, attachments, and authentication state. The online
  backup producer publishes validated SQLite generations beneath
  `/srv/backups/services/trilium`; see [trilium.md](./trilium.md).
- `/srv` itself: `0755 root:root`; service accounts cannot create arbitrary
  top-level directories.
- BookOrbit owns `/srv/bookorbit/data` as `bookorbit:bookorbit` (UID/GID 1200),
  mode `0750`. Its isolated pgvector/PostgreSQL container initializes PGDATA
  beneath `/srv/bookorbit/database`; the mount root is `0700 999:999` and
  PostgreSQL owns the `18/docker` child (the bind mount targets
  `/var/lib/postgresql`, matching the PostgreSQL 18 image volume).
  `/srv/media/books` is `2770 root:bookorbit`, mounted
  read-only into the app. Database, application data, and source books are
  exported together beneath `/srv/backups/services/bookorbit`. See
  [bookorbit.md](./bookorbit.md) for setup and recovery. No books are imported yet.
- Printer maintenance bookkeeping lives in `/srv/printer-maintenance`, mode
  `0700`, owned by `printer-maintenance:printer-maintenance`. It is excluded
  from Kopia; preserve its outstanding-job token during routine rebuilds.
  See [printer-maintenance.md](./printer-maintenance.md) before resetting it.

Avoid recursive ownership changes during routine activation. A service module
should declare exact paths and modes using systemd tmpfiles or an appropriate
NixOS module option. Any ownership migration for existing data needs a reviewed,
one-time procedure.

## Service-module checklist

Before adding persistent application state, document and configure:

1. Every state path the application writes.
2. The user and group owning each path.
3. Required sharing between processes or services.
4. Whether the data is critical, reconstructable, or disposable.
5. Which paths Kopia will snapshot.
6. Database-consistent export requirements.
7. The restore destination, ownership, and order of operations.

Prefer `/srv/<service>/...` for application-owned state and separate shared
content by purpose, such as `/srv/media/...`. Native NixOS modules sometimes
require state under `/var/lib`; when moving that state is unsupported or brittle,
document the exception rather than hiding it behind an ad hoc symlink.

## Verification

After activation, verify the mount and permissions:

```console
findmnt --real /srv
stat --format '%U:%G %a %n' /srv
```

Expected ownership is `root:root 755 /srv`. Before enabling any stateful
service, also confirm that its intended directory resolves beneath this mount:

```console
findmnt --target /srv/SERVICE
```

The reported target must be backed by the `/srv` Btrfs subvolume, not merely by
the root filesystem.
