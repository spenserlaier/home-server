# Home Server Implementation Plan

## 1. Goal

Build a reproducible, replaceable home server on NixOS running on the GMKtec M5 Ultra mini PC.

The server should prioritize:

* Declarative configuration
* Reproducibility
* Clear separation between system configuration and persistent state
* Straightforward disaster recovery
* Minimal manual configuration
* Conservative handling of stateful applications
* Easy incremental deployment
* No unnecessary public internet exposure

The intended operational model is:

> The NixOS configuration reconstructs the server. Persistent storage and backups reconstruct the data.

The implementation should favor understandable, boring infrastructure over unnecessary abstraction.

---

# 2. Target Services

## Core services

### Jellyfin

Media server.

Requirements:

* Persistent configuration and metadata
* Media stored separately from application configuration
* Hardware acceleration should be supported where practical
* Initially LAN-only
* Accessible through a stable local hostname

### Paperless-ngx

Document archive and OCR system.

Requirements:

* Persistent database, media, and application state
* Dedicated consumption directory
* Integration with Brother ADS-4300N scanner
* Scanner should be able to send documents directly to the server using SMB/CIFS
* Scanner credentials should have minimal privileges
* Initial workflow should prioritize reliability over sophisticated automatic classification

Desired initial workflow:

```text
Brother ADS-4300N
        ↓
SMB/CIFS share
        ↓
Paperless consumption directory
        ↓
OCR / indexing / archive
```

### Invoice Ninja

Custom/modded Invoice Ninja fork currently running on another machine.

This is business-critical state and should be treated conservatively.

Requirements:

* Run the existing custom fork rather than upstream Invoice Ninja
* Exact source revision must be reproducible/pinned
* Prefer OCI container isolation unless there is a compelling reason otherwise
* NixOS should declaratively control the container
* Persistent database and application storage must live outside the container
* Preserve application secrets, including the Laravel application key
* Migration must occur only after the new deployment works independently
* Do not combine migration with database-engine upgrades or other unrelated modernization
* Preserve rollback path to the existing desktop deployment until validation is complete

### Pi-hole

Replace the existing Raspberry Pi DNS/Pi-hole deployment.

Requirements:

* Reliable LAN DNS
* Stable IP
* DNS configuration should remain operationally separate from unrelated application services
* Pi-hole should not be introduced until the base NixOS host is proven stable
* Migration should allow easy rollback to the existing DNS server

### Backups

Use Kopia with the existing Backblaze B2/S3-compatible repository.

Requirements:

* Declarative scheduling through systemd/NixOS
* Credentials must not be stored in the public Nix store
* Back up important persistent state
* Generate database-consistent dumps before filesystem backup where appropriate
* Establish retention policies
* Document and test restoration

---

# 3. Secondary Services

These should be implemented after the core platform is stable.

### Audiobookshelf

Requirements:

* Persistent library and metadata
* Local reverse-proxy endpoint
* Media storage separate from application state

### Moodist

Requirements:

* Low operational priority
* Containerization is acceptable/preferred if upstream deployment is container-oriented
* Avoid spending significant effort producing native Nix packaging unless it clearly improves maintainability

### Tailscale / Headscale

Remote access is explicitly a later phase.

Initial deployment should be LAN-only.

However, architecture should avoid decisions that make future private remote access difficult.

Requirements:

* No direct WAN exposure
* Stable DNS names
* Central reverse proxy
* Avoid hardcoding LAN addresses into application state
* Tailscale may be introduced first
* Headscale may be evaluated later if self-hosted coordination is desirable

---

# 4. Architectural Principles

## 4.1 NixOS owns the host

Use NixOS for:

* Filesystems
* Networking
* Firewall
* Users/groups
* systemd units
* Service configuration
* Reverse proxy
* Containers
* Backup schedules
* Secrets integration
* Application package versions where practical

Manual server configuration should be minimized.

Any manual step required for deployment or recovery should be documented.

---

## 4.2 Prefer native NixOS services where mature

Prefer native NixOS modules for applications that have good first-class support.

Likely native services include:

* Jellyfin
* Paperless-ngx
* Samba
* Reverse proxy
* Backup timers/jobs
* Supporting databases where sensible

Use containers where containerization materially reduces maintenance complexity.

Likely container candidates include:

* Custom Invoice Ninja fork
* Moodist
* Potentially Audiobookshelf depending on NixOS module/package quality

Do not introduce Docker/Podman merely for consistency.

Containerization is a tool, not the default architecture.

---

# 5. Persistent State Layout

Use `/srv` as the primary persistent application-data boundary.

Target layout:

```text
/srv/
├── paperless/
│   ├── consume/
│   ├── media/
│   ├── data/
│   └── export/
│
├── invoiceninja/
│   ├── database/
│   ├── storage/
│   ├── backups/
│   └── config/
│
├── jellyfin/
│   ├── config/
│   └── cache/
│
├── media/
│   ├── movies/
│   └── tv/
│
├── audiobooks/
│   ├── library/
│   └── metadata/
│
├── moodist/
│   └── data/
│
└── backups/
    └── database/
```

Exact paths may change where NixOS modules impose sensible defaults, but the conceptual boundary should remain.

Persistent data must not live only inside ephemeral container filesystems.

---

# 6. Data Classification

Treat storage according to importance.

## Tier 1: Critical / irreplaceable

Examples:

* Invoice Ninja database
* Invoice Ninja uploads
* Paperless database
* Paperless archived documents
* Application secrets
* Important configuration not stored in Git

Backup frequently and verify restorability.

## Tier 2: Valuable but reconstructable

Examples:

* Jellyfin metadata
* Audiobookshelf metadata
* Generated thumbnails
* Application metadata

Backup where practical.

## Tier 3: Bulk/reacquirable media

Examples:

* Movies
* TV
* Potentially some audiobook media

Do not automatically assume all bulk media belongs in Backblaze.

Backup strategy should consider storage cost and replaceability.

---

# 7. Repository Structure

Prefer modular Nix configuration over one monolithic `configuration.nix`.

Initial target:

```text
.
├── flake.nix
├── flake.lock
│
├── hosts/
│   └── homeserver/
│       ├── default.nix
│       ├── hardware-configuration.nix
│       ├── networking.nix
│       └── storage.nix
│
├── modules/
│   ├── base/
│   │   ├── server.nix
│   │   ├── users.nix
│   │   ├── firewall.nix
│   │   └── secrets.nix
│   │
│   ├── services/
│   │   ├── jellyfin.nix
│   │   ├── paperless.nix
│   │   ├── samba.nix
│   │   ├── invoiceninja.nix
│   │   ├── pihole.nix
│   │   ├── audiobookshelf.nix
│   │   └── moodist.nix
│   │
│   ├── backup/
│   │   └── kopia.nix
│   │
│   └── networking/
│       ├── reverse-proxy.nix
│       └── local-dns.nix
│
├── secrets/
│   └── ...
│
├── scripts/
│   ├── backup/
│   ├── migration/
│   └── restore/
│
└── docs/
    ├── architecture.md
    ├── deployment.md
    ├── backup-and-restore.md
    ├── invoiceninja-migration.md
    └── scanner-setup.md
```

Do not create empty files/modules merely to satisfy this proposed layout.

Add structure as functionality is implemented.

---

# 8. Secrets

Choose a declarative secrets-management solution suitable for NixOS.

Preferred candidates:

* sops-nix
* agenix

Secrets may include:

* Backblaze credentials
* Kopia repository credentials
* Invoice Ninja application key
* Invoice Ninja database password
* SMTP credentials
* Paperless secrets
* Samba scanner password
* Future Tailscale/Headscale credentials

Rules:

* Never place plaintext secrets in Git.
* Never expose secrets through the Nix store unnecessarily.
* Document recovery/bootstrap requirements.
* Keep the number of manually provisioned secrets small.

---

# 9. Networking

## Stable host identity

The MiniPC must have a predictable LAN address.

Prefer:

* DHCP reservation on router

or:

* Explicit static configuration if justified

Avoid accidental dependency on transient DHCP addressing.

## Local service names

Use local DNS rather than relying permanently on ports and IP addresses.

Suggested names:

```text
jellyfin.home.arpa
paperless.home.arpa
invoice.home.arpa
books.home.arpa
moodist.home.arpa
```

Use `home.arpa`, not `.local`.

## Reverse proxy

Introduce a central reverse proxy.

Likely options:

* Caddy
* nginx

The proxy should provide stable application endpoints and make future HTTPS/Tailscale integration straightforward.

Avoid exposing arbitrary application ports across the LAN when unnecessary.

---

# 10. Paperless Scanner Integration

Create a dedicated Samba share corresponding to the Paperless consumption directory.

Example conceptual configuration:

```text
Share:
    paperless

Path:
    /srv/paperless/consume

Scanner user:
    scanner

Permissions:
    write-only/minimal practical permissions
```

The Brother ADS-4300N should be configured through its own web interface with a Scan-to-Network profile.

Initial goal:

> Load pages, press a single Paperless button, and have the documents appear automatically in Paperless.

Avoid complex scanner workflows initially.

Potential later enhancements:

* Separate scan profiles
* Different source directories
* Automatic Paperless workflows
* Receipt/document tagging
* Duplex/profile variations

Do not block the initial deployment on these enhancements.

---

# 11. Invoice Ninja Deployment Strategy

Treat Invoice Ninja as an independently versioned application artifact.

Preferred model:

```text
custom Invoice Ninja Git revision
              ↓
       reproducible OCI image
              ↓
NixOS virtualisation.oci-containers
              ↓
persistent DB + persistent storage
```

Do not:

* `git pull` application source during boot
* implicitly run latest upstream images
* depend on mutable tags where avoidable
* keep important state inside the container filesystem

Prefer:

* pinned Git revision
* pinned image tag/digest
* or Nix-built OCI image from a pinned source

The deployment must make it possible to identify exactly which source revision is currently running.

---

# 12. Invoice Ninja Migration

Migration is a distinct phase.

Before migration, capture:

* Exact running fork revision
* Database engine/version
* Database dump
* Persistent storage/uploads
* Application `.env` values
* Laravel `APP_KEY`
* SMTP configuration
* Scheduled-task configuration
* Worker/queue configuration
* Any custom dependencies or build steps

Migration workflow:

```text
existing desktop instance
        ↓
capture DB + state + configuration
        ↓
build clean server deployment
        ↓
restore captured data
        ↓
test isolated deployment
        ↓
validate
        ↓
switch production use
        ↓
retain old deployment temporarily for rollback
```

Validation should include:

* Authentication
* Client records
* Invoice records
* Attachments
* PDFs
* Email delivery
* Recurring invoices if used
* Scheduler
* Queue/background jobs
* Custom fork behavior
* Existing integrations

Do not change database engines/major versions during the initial migration unless strictly required.

---

# 13. Backup Strategy

Use Kopia and the existing Backblaze repository.

Backups should include application-consistent database data.

Preferred workflow:

```text
systemd timer
      ↓
pre-backup script
      ↓
database dumps
      ↓
Kopia snapshot
      ↓
Backblaze
```

Example database dump destination:

```text
/srv/backups/database/
├── invoiceninja.sql.zst
└── paperless.sql.zst
```

Kopia should then capture:

* Database dumps
* Paperless documents/media
* Invoice Ninja storage
* Relevant application metadata
* Other designated persistent state

Do not treat a successful upload as proof that backups work.

Create documented restore procedures.

Eventually perform a full restore test.

---

# 14. Deployment Phases

Implementation should proceed incrementally.

## Phase 0 — Repository/bootstrap

Deliverables:

* Flake
* Host definition
* Formatting/linting strategy
* Basic repository documentation
* Initial module structure

Success criteria:

* Configuration evaluates
* Development workflow is clear

---

## Phase 1 — Base NixOS host

Implement:

* Boot/install configuration
* Networking
* Stable IP strategy
* SSH
* Basic users
* Firewall
* Timezone/localization
* Storage mounts
* Nix settings
* System update/rebuild workflow

Success criteria:

* MiniPC boots reliably
* SSH access works
* Rebuilds are deterministic
* Reboot does not require manual intervention

---

## Phase 2 — Persistent storage and secrets

Implement:

* `/srv` structure
* Ownership/groups
* Secrets framework
* Persistent storage conventions

Success criteria:

* Services can consume secrets without plaintext Git exposure
* Persistent directories survive service recreation/rebuild

---

## Phase 3 — Reverse proxy and low-risk services

Implement:

* Reverse proxy
* Jellyfin
* Audiobookshelf and/or Moodist if convenient

Success criteria:

* Services work through stable local names
* Rebuild/reboot preserves state

Use this phase to validate the broader service-module conventions before deploying critical applications.

---

## Phase 4 — Paperless

Implement:

* Paperless
* Database
* Consumption directory
* Samba scan share
* Scanner-specific account
* Brother scanner profile documentation

Success criteria:

* Physical scan reaches Paperless without desktop intervention
* OCR completes
* Archived document survives reboot/rebuild
* Scanner cannot access unrelated server data

---

## Phase 5 — Backups

Implement:

* Kopia configuration
* Backblaze access
* systemd timer
* database pre-backup hooks
* retention policy
* backup logs/status

Success criteria:

* Successful remote snapshot
* Database dumps included
* At least one documented test restore succeeds

Critical services should not be migrated until this phase is operational.

---

## Phase 6 — Invoice Ninja clean deployment

Implement:

* Reproducible custom fork artifact
* OCI configuration
* Database service
* Persistent storage
* Scheduler
* Queue worker
* Reverse proxy
* Secrets

Initially use empty/test data.

Success criteria:

* Application runs correctly
* Custom modifications are present
* Scheduler and workers operate
* Deployment survives rebuild/reboot

---

## Phase 7 — Invoice Ninja migration

Implement:

* Export desktop state
* Restore into server instance
* Validate application
* Switch normal use to server

Success criteria:

* Historical data matches
* Attachments work
* Invoice generation works
* Email works
* Custom behavior works
* Backup succeeds after migration

Keep existing instance intact until validation is complete.

---

## Phase 8 — Pi-hole migration

Implement:

* Pi-hole
* Existing DNS/blocking configuration as appropriate
* `home.arpa` records
* Test-client DNS migration
* LAN-wide DNS migration

Workflow:

```text
deploy Pi-hole
      ↓
test directly
      ↓
point one client at it
      ↓
verify
      ↓
change DHCP-advertised DNS
```

Success criteria:

* LAN DNS works reliably
* Local service names resolve
* Rollback remains easy

Do not make initial NixOS deployment dependent on Pi-hole being functional.

---

## Phase 9 — Hardening and operational polish

Consider:

* Automated update strategy
* Reboot policy
* SMART/storage health monitoring
* Backup failure notifications
* Disk-space alerts
* Service health checks
* Log retention
* UPS support if added later
* Documented disaster recovery

Avoid adding monitoring infrastructure substantially more complex than the server being monitored.

---

## Phase 10 — Remote access

Optional later work:

* Tailscale
* Private service access
* DNS integration
* Evaluate Headscale afterward

Remote access must not require public exposure of application services.

---

# 15. Implementation Rules for AI-Assisted Development

When modifying this repository:

1. Make small, reviewable changes.
2. Do not implement multiple deployment phases at once unless they are tightly coupled.
3. Preserve existing working behavior.
4. Prefer NixOS-native functionality over custom scripts when functionality is equivalent.
5. Prefer simple systemd units over bespoke daemons.
6. Prefer explicit configuration over hidden defaults for critical behavior.
7. Do not introduce Kubernetes.
8. Do not introduce a generic container orchestration stack.
9. Do not introduce Terraform/Ansible unless a concrete need emerges.
10. Do not expose services publicly to the internet.
11. Do not commit secrets.
12. Do not use mutable application versions for critical services.
13. Do not migrate production data until a clean deployment has been tested.
14. Do not perform unrelated upgrades during migrations.
15. Add documentation when a manual operational step is introduced.
16. Keep restoration in mind whenever new persistent state is added.

Before implementing a service, determine:

* What package/module provides it?
* What state does it create?
* Where does that state live?
* What secrets does it require?
* What network ports/interfaces does it expose?
* Does it need a database?
* Does it need background jobs?
* What must be backed up?
* What would restoration require?

---

# 16. Testing Expectations

The project does not need elaborate unit tests for static configuration merely for the sake of testing.

Prioritize useful checks:

```bash
nix flake check
```

Configuration evaluation/build checks should run before deployment.

Where practical:

* build configuration before switch
* validate service config syntax
* confirm systemd units are healthy
* perform HTTP health checks
* verify persistent directories
* verify backup snapshots
* perform restoration tests

For major changes, prefer:

```text
evaluate
→ build
→ activate
→ verify
```

rather than immediately switching an unverified configuration.

---

# 17. Documentation Expectations

Keep operational documentation alongside the configuration.

At minimum document:

## Installation

How to rebuild the server from a fresh NixOS installation.

## Secrets bootstrap

What must exist before the configuration can activate successfully.

## Backup restoration

How to restore each critical service.

## Invoice Ninja migration

Exact migration procedure and rollback plan.

## Paperless scanner

Brother ADS-4300N profile configuration.

## DNS

How Pi-hole becomes the LAN resolver and how to roll back.

Manual commands that are essential to disaster recovery should not exist only in shell history.

---

# 18. Definition of Done

The initial home-server project is considered complete when:

* NixOS host can be recreated from repository configuration
* Persistent state is clearly separated from system configuration
* Jellyfin is functional
* Paperless accepts scans directly from the Brother scanner
* Invoice Ninja custom fork has been successfully migrated
* Pi-hole has replaced the previous Raspberry Pi deployment
* Kopia backs up critical data to Backblaze
* At least one meaningful restore test has been performed
* Core services use stable local hostnames
* No core service requires public WAN exposure
* Required manual recovery steps are documented

Audiobookshelf, Moodist, and remote access may remain follow-up work without blocking completion.

---

# 19. Immediate Next Step

Begin with Phase 0 and Phase 1 only.

Initial implementation target:

1. Inspect the existing repository.
2. Establish the flake and host structure.
3. Create the base NixOS host configuration.
4. Configure networking and SSH.
5. Define initial storage conventions.
6. Verify the configuration evaluates/builds.
7. Document how the MiniPC will be installed and rebuilt.

Do not begin deploying application services until the base host design is stable.

