# homeserver

Declarative NixOS configuration for the `homeserver` host. The architecture and
deployment phases are described in [PLAN.md](./PLAN.md).

The complete bare-metal installation and recovery procedure is in
[docs/installation.md](./docs/installation.md).
Persistent-state ownership and layout conventions are documented in
[docs/persistent-state.md](./docs/persistent-state.md).
Secrets bootstrap, editing, deployment, and recovery are documented in
[docs/secrets.md](./docs/secrets.md).
Private DNS, Caddy bootstrap, and Porkbun DNS-01 setup are documented in
[docs/networking.md](./docs/networking.md).
Jellyfin deployment, state, media, and verification are documented in
[docs/jellyfin.md](./docs/jellyfin.md).
Paperless deployment, persistence, exports, and initial verification are
documented in [docs/paperless.md](./docs/paperless.md).
Brother scanner SFTP ingestion and verification are documented in
[docs/paperless-scanner.md](./docs/paperless-scanner.md).
InvoiceShelf deployment, persistence, backup, and initial verification are
documented in [docs/invoiceshelf.md](./docs/invoiceshelf.md).
Encrypted off-host backup initialization, verification, and restore operations
are documented in [docs/backup-and-restore.md](./docs/backup-and-restore.md).

## Current scope

This repository implements the platform through the empty InvoiceShelf
deployment configuration (Phase 6; deployment validation remains):

- NixOS 26.05 on `x86_64-linux`
- UEFI/systemd-boot
- DHCP networking (use a router reservation for a stable address)
- SSH access for `spenser-admin` and a default-deny firewall
- a Disko-managed GPT/Btrfs layout with persistent state beneath `/srv`
- SOPS-managed runtime secrets
- private HTTPS through Caddy and Porkbun DNS-01
- Jellyfin with hardware transcoding and native backup artifacts
- Paperless-ngx with PostgreSQL, native exports, and direct scanner ingestion
- encrypted, immutable off-host Kopia generations in Backblaze B2
- InvoiceShelf 2.4.2 and MariaDB 10.11.14 pinned by immutable OCI digests

The next acceptance milestone is deploying and validating InvoiceShelf with
empty test data. Migration of the existing Invoice Ninja records remains a
separate later step. Pi-hole, operational hardening, remote access, and
secondary services are also intentionally deferred.

## Development checks

Format the repository:

```console
nix fmt
```

Evaluate every flake output without attempting an `x86_64-linux` build on an
Apple Silicon development machine:

```console
nix flake check --no-build --all-systems
```

On an `x86_64-linux` Nix machine, build without activating:

```console
nix build .#nixosConfigurations.homeserver.config.system.build.toplevel
```

## Installation guardrail

Disko repartitions its configured target and destroys all data on it. Follow the
identity checks and explicit stop point in the installation runbook before
running it.

## SSH access

The administrator public key is intentionally committed because NixOS needs it
to recreate access. Its fingerprint is:

```text
SHA256:lQ+X2Tmh2mYvC2uvjyRBRpcnQAPfTyjW6h+WNtigSFc
```

A public key is not an authentication secret, but committing it publicly links
the key identity to this server and GitHub account. The private key must remain
outside this repository.

SSH permits public-key authentication only: password and keyboard-interactive
authentication are disabled, and root cannot log in over SSH. The
`spenser-admin` user has passwordless `sudo`, avoiding an undeclared password
dependency after key-based login. Before ending the installer session, verify a
fresh SSH login and `sudo` command from a second terminal. Loss of the private
key requires local console or NixOS installer recovery; a second declarative
recovery key can be added later if desired.

## Public-repository rules

- Never commit passwords, private keys, API tokens, `.env` files, or decrypted
  secret files.
- Treat application hostnames, usernames, public keys, disk identifiers, and
  hardware details as public metadata once committed.
- Inspect `jj diff --git` and `jj status` before every push.
- SOPS must decrypt credentials only on the target host; plaintext credentials
  must never enter the Nix store or repository history.
