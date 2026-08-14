# Secrets with sops-nix

This repository uses SOPS with age encryption and `sops-nix` for runtime secret
delivery. Encrypted SOPS files are safe to commit; plaintext secret values and
private keys are not.

## Key model

Every secret is encrypted to two public recipients:

1. `spenser-admin`: the existing laptop SSH key. This is the administrative and
   disaster-recovery identity.
2. `homeserver`: the MiniPC's persistent Ed25519 SSH host key. `sops-nix`
   converts the private host key to an age identity during activation.

Either corresponding private key can decrypt a secret. This is intentional
redundancy, not two-factor encryption. Do not use the server as the only
recipient: after a failed boot disk, that would make encrypted backups and
repository secrets inaccessible unless the old host private key survived.

The public recipients live in `.sops.yaml`. Public keys are not credentials,
but they are public metadata. Private keys never belong in this repository or
the Nix store.

## One-time bootstrap

The initial bootstrap is complete when `.sops.yaml` contains the MiniPC's
`age1...` host recipient. Repeat these steps after replacing the machine or its
SSH host identity.

### 1. Get the server recipient

On the installed MiniPC, confirm the host public-key fingerprint and convert the
public key to an age recipient:

```console
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
nix shell nixpkgs#ssh-to-age -c sh -c \
  'ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub'
```

The second command prints a public value beginning with `age1`. It is safe to
copy into the public repository. Do not display or copy the private file without
the `.pub` suffix.

Replace the `homeserver` recipient in `.sops.yaml` with that `age1...` value.

### 2. Verify laptop recovery access

The laptop recipient in `.sops.yaml` is the same Ed25519 public key already used
for SSH administration. SOPS can use the matching default private key at
`~/.ssh/id_ed25519`. Confirm its fingerprint on the laptop:

```console
ssh-keygen -lf ~/.ssh/id_ed25519.pub
```

It must report:

```text
SHA256:lQ+X2Tmh2mYvC2uvjyRBRpcnQAPfTyjW6h+WNtigSFc
```

If SOPS does not find the key automatically, invoke it with:

```console
SOPS_AGE_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519" sops COMMAND
```

### 3. Validate and activate the framework

After recording or rotating the recipient, commit and push the public policy
change. On the server, pull it and activate:

```console
nix flake check --no-build --all-systems
sudo nixos-rebuild build --flake .#homeserver
sudo nixos-rebuild switch --flake .#homeserver
```

At this stage no runtime secrets are declared, so `/run/secrets` may be empty or
absent.

## Creating a secret file

Create and edit encrypted files on the laptop, not on the server. From the
repository root, enter a temporary shell if `sops` is not already installed,
then edit the file:

```console
nix shell nixpkgs#sops
sops secrets/homeserver.yaml
```

The editor opens a temporary decrypted representation. Use namespaced keys so
their consumers are unambiguous, for example:

```yaml
kopia:
  repository_password: replace-me
  b2_key_id: replace-me
  b2_application_key: replace-me
paperless:
  secret_key: replace-me
invoiceshelf:
  app_key: replace-me
  database_password: replace-me
  database_root_password: replace-me
```

On save, SOPS writes only encrypted values plus recipient metadata. Before
committing, verify that the file contains SOPS metadata and no plaintext values:

```console
sops filestatus secrets/homeserver.yaml
jj diff --git secrets/homeserver.yaml
```

Do not create placeholder secrets merely to populate the directory. Add a key
when a service module is ready to consume it.

## Declaring a runtime secret

A service module declares only the keys it consumes. For example:

```nix
{
  sops = {
    defaultSopsFile = ../../secrets/homeserver.yaml;
    secrets."paperless/secret_key" = {
      owner = "paperless";
      group = "paperless";
      mode = "0400";
    };
  };
}
```

At activation, `sops-nix` decrypts this into a root-managed file below
`/run/secrets`. The plaintext does not enter the Nix store. Pass the resulting
path to the service; do not read the secret into a Nix string.

After deployment, check metadata without printing the value:

```console
sudo stat /run/secrets/paperless/secret_key
```

## Adding or rotating recipients

When `.sops.yaml` recipients change, existing encrypted files do not update
automatically. From a machine that can already decrypt them, run:

```console
sops updatekeys secrets/homeserver.yaml
```

Review the recipient change before committing it. Remove an old recipient only
after confirming another private identity can decrypt every secret.

## Recovery

For a replacement server:

1. Use the laptop key to decrypt existing repository secrets.
2. Install NixOS and let it create a new SSH host key.
3. Convert the new host public key with `ssh-to-age`.
4. Replace the old server recipient in `.sops.yaml`.
5. Run `sops updatekeys` on every encrypted file.
6. Commit and deploy the re-encrypted files.

Protect and back up the laptop private key separately from this server. Losing
both recipient private keys makes the SOPS files cryptographically unrecoverable.

## Public-repository review

Before every push involving secrets:

```console
jj status
jj diff --git
sops filestatus secrets/homeserver.yaml
```

Never commit editor swap files, shell exports containing credentials, decrypted
copies, SSH private keys, or command output containing secret values.
