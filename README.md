# homeserver

Declarative NixOS configuration for the `homeserver` host. The architecture and
deployment phases are described in [PLAN.md](./PLAN.md).

## Current scope

This repository currently defines the Phase 0 and initial Phase 1 host baseline:

- NixOS 26.05 on `x86_64-linux`
- UEFI/systemd-boot
- DHCP networking (use a router reservation for a stable address)
- SSH access for `spenser-admin`
- a default-deny firewall with SSH allowed
- a Disko-managed GPT/Btrfs layout

No application services or secrets are configured yet.

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

## Installation guardrails

Disko repartitions its target and destroys data on it. Before installation:

1. Boot the GMKtec from a NixOS installer.
2. Confirm UEFI boot is enabled.
3. Identify the intended disk with `ls -l /dev/disk/by-id/`.
4. Replace `REPLACE-WITH-TARGET-DISK-ID` in
   `hosts/homeserver/storage.nix` with that disk's full stable path.
5. Review the resulting diff and independently confirm the disk identity.

The installation commands will be documented and exercised once the physical
disk identifier and generated hardware configuration are available. Do not run
Disko while the placeholder remains.

## SSH bootstrap

The administrator public key is intentionally committed because NixOS needs it
to recreate access. Its fingerprint is:

```text
SHA256:lQ+X2Tmh2mYvC2uvjyRBRpcnQAPfTyjW6h+WNtigSFc
```

A public key is not an authentication secret, but committing it publicly links
the key identity to this server and GitHub account. The private key and all
passwords must remain outside this repository.

Password authentication is temporarily enabled for bootstrap. After key-based
login is verified from a second terminal, set `PasswordAuthentication = false`
in `modules/base/server.nix`, rebuild, and verify a fresh login before closing
the existing session. The user must receive a local password during installation
for password-based SSH and password-protected `sudo` to function.

## Public-repository rules

- Never commit passwords, private keys, API tokens, `.env` files, or decrypted
  secret files.
- Treat application hostnames, usernames, public keys, disk identifiers, and
  hardware details as public metadata once committed.
- Inspect `jj diff --git` and `jj status` before every push.
- A future secrets framework must decrypt credentials only on the target host;
  plaintext credentials must never enter the Nix store or repository history.

