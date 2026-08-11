# Bare-metal installation and recovery

This runbook installs the `homeserver` NixOS configuration on the GMKtec from a
minimal NixOS installer. It is also the starting point after a boot-drive
failure or hardware replacement.

Commands marked **destructive** erase the disk configured in
`hosts/homeserver/storage.nix`. Read the surrounding checks before running them.

## What the repository restores

The repository restores the operating system, disk layout, users, networking,
and declarative services. It does not restore application data or secrets.
Those will come from the documented Kopia and secrets recovery procedures once
those phases are implemented.

The committed disk identifier is specific to the current drive. Replacing the
drive requires updating it before running Disko. A hardware upgrade may also
require regenerating `hosts/homeserver/hardware-configuration.nix`.

## Prerequisites

- A NixOS 26.05 or newer minimal installer USB
- Keyboard and monitor access
- Wired LAN with DHCP and internet access
- UEFI boot enabled in firmware
- This public repository available from GitHub
- The private key corresponding to the declared `spenser-admin` public key

## 1. Boot and prepare the installer

Boot the installer in UEFI mode. The following changes the live console font
only; the installed system declares the same font separately:

```console
sudo setfont ter-132n
```

Confirm that the installer has network access and was booted using UEFI:

```console
ip -brief address
ping -c 3 cache.nixos.org
test -d /sys/firmware/efi && echo "UEFI boot confirmed"
```

Enter a temporary shell containing Jujutsu and clone the repository:

```console
nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#jujutsu nixpkgs#git
jj git clone https://github.com/spenserlaier/home-server.git
cd home-server
```

Inspect the checkout and evaluate it before touching a disk:

```console
jj log -r @ -T 'commit_id ++ "  " ++ description ++ "\n"'
nix flake check --no-build --all-systems
```

Confirm that the checked-out revision contains the changes intended for this
installation. Do not install an older GitHub revision merely because a newer
change still exists only on another computer.

## 2. Verify the target disk

List stable identifiers and the block-device topology:

```console
ls -l /dev/disk/by-id/
lsblk --output NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
```

Then inspect the configured target:

```console
sed -n '/device =/p' hosts/homeserver/storage.nix
```

The `/dev/disk/by-id/...` value must resolve to the intended internal drive:

```console
readlink -f /dev/disk/by-id/REPLACE_WITH_THE_REVIEWED_ID
```

For a replacement drive, edit `hosts/homeserver/storage.nix` to use its stable
identifier, then review the change:

```console
jj diff --git hosts/homeserver/storage.nix
```

Stop unless the identifier, model, serial, and capacity all describe the disk
that may be completely erased. Disconnect other removable storage when
practical.

## 3. Partition, format, and mount

The following command is **destructive**. It uses the Disko revision pinned by
this repository, destroys the configured partition table and filesystems,
creates the GPT/Btrfs layout, and mounts it below `/mnt`:

```console
sudo nix run .#disko -- \
  --mode destroy,format,mount \
  ./hosts/homeserver/storage.nix
```

Verify the result before continuing:

```console
findmnt --real --submounts --output TARGET,SOURCE,FSTYPE,OPTIONS /mnt
lsblk --fs
```

## 4. Capture hardware configuration

Generate hardware-specific boot modules without duplicating the filesystems
already owned by Disko:

```console
sudo nixos-generate-config \
  --root /mnt \
  --no-filesystems \
  --show-hardware-config \
  > hosts/homeserver/hardware-configuration.nix
```

Snapshot the new file so flake evaluation can see it, then review it. In a
Jujutsu colocated repository, `jj status` performs that snapshot:

```console
jj status
sed -n '1,240p' hosts/homeserver/hardware-configuration.nix
nix flake check --no-build --all-systems
```

The generated file commonly contains initrd modules, CPU microcode settings,
and other detected hardware. It must not contain `fileSystems` or `swapDevices`
when generated with `--no-filesystems`; Disko owns those definitions.

Commit and push a reviewed hardware configuration after the machine is working.
Hardware identifiers are not credentials, but they become public metadata in
this repository.

For a same-hardware recovery, reuse the committed hardware configuration. For a
motherboard, storage-controller, or CPU-platform change, regenerate and compare
it before installation.

## 5. Install NixOS

Build the configuration before installing it:

```console
sudo nixos-rebuild build --flake .#homeserver
```

Install without creating a root password. Administration is through the
declarative SSH key and passwordless `sudo`:

```console
sudo nixos-install --flake .#homeserver --no-root-passwd
```

Confirm that the installed system contains the administrator key:

```console
sudo grep -R "homeserver admin" /mnt/etc/ssh/authorized_keys.d/
```

Do not reboot if the install failed or the authorized key is absent. Correct the
configuration and rerun `nixos-install`; Disko does not need to be rerun.

## 6. First boot and access verification

Reboot, remove the installer USB, and select the internal drive:

```console
sudo reboot
```

Find the DHCP lease in the router, then reserve that address for `homeserver`.
From a machine containing the matching private key:

```console
ssh spenser-admin@HOMESERVER_IP
sudo true
hostnamectl hostname
systemctl --failed
findmnt --real --submounts --output TARGET,SOURCE,FSTYPE,OPTIONS /
```

Expected results:

- key-based SSH succeeds without an account password;
- `sudo true` succeeds without a password;
- the hostname is `homeserver`;
- no systemd units have failed;
- the declared Btrfs subvolumes and EFI partition are mounted.

Keep the installer USB available until these checks pass. Because root and
password SSH logins are disabled, a lost or incorrect private key requires local
console or installer recovery.

## 7. Establish the on-host checkout

After first login, clone the repository for routine rebuilds:

```console
jj git clone https://github.com/spenserlaier/home-server.git
cd home-server
```

Build before activating changes:

```console
nix flake check --no-build --all-systems
sudo nixos-rebuild build --flake .#homeserver
sudo nixos-rebuild switch --flake .#homeserver
```

After activation, verify a fresh SSH session before closing the existing one.

## Reinstall without repartitioning

If the filesystems are intact and only NixOS must be reinstalled, do not use
Disko's `destroy` or `format` modes. Boot the installer, clone the repository,
and mount the declared layout with:

```console
sudo nix run .#disko -- \
  --mode mount \
  ./hosts/homeserver/storage.nix
```

Then run `nixos-install` as shown above. This preserves `/srv`, but restoration
procedures should still assume that important state can be lost and must exist
in verified backups.

## Recovery notes

- A failed activation can usually be rolled back by choosing an older
  generation in the systemd-boot menu.
- A failed installation can be rerun after correcting the configuration.
- Do not rerun destructive Disko modes merely to fix a Nix evaluation or
  installation error.
- Before repurposing or replacing a drive, confirm that critical application
  data has a verified remote snapshot and a tested restoration path.
