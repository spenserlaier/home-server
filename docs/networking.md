# Private networking and DNS

Private services use names below `home.hyrax.fyi`. They are not published with
public A or AAAA records and the router must not forward ports 80 or 443 from
the internet. Caddy is the only HTTP entry point for application services.

The target resolution path is:

```text
LAN client      -> Pi-hole -> homeserver LAN address
NetBird client  -> Pi-hole -> homeserver LAN address through NetBird routing
public resolver -> no private address
```

Until Pi-hole is migrated, add individual records to the existing router DNS
if it supports them. Otherwise, add a temporary hosts-file entry on the client:

```text
HOMESERVER_LAN_ADDRESS caddy.home.hyrax.fyi
```

Do not publish the LAN address through Porkbun. Public DNS is used only for
ACME DNS-01 challenge records, which Caddy creates and removes automatically.

## Caddy health endpoint

The bootstrap configuration initially used plain HTTP to test local DNS and
firewall behavior before provisioning ACME credentials. The active endpoint is
now:

```text
https://caddy.home.hyrax.fyi/healthz
```

After deployment, verify it from another LAN machine:

```console
curl --fail https://caddy.home.hyrax.fyi/healthz
```

The response must be `ok`. Other paths are aborted rather than serving a
default site. Requests over HTTP redirect to HTTPS.

## Porkbun DNS-01 credentials

Create a Porkbun API key for certificate management and enable API access for
`hyrax.fyi`. Treat both the API key and secret key as secrets. Add them to
`secrets/homeserver.yaml` using the workflow in `docs/secrets.md`:

```yaml
caddy:
  porkbun_api_key: replace-me
  porkbun_api_secret_key: replace-me
```

The reverse-proxy module declares both secret paths and renders a `0400`,
`caddy:caddy` environment file below `/run/secrets-rendered`. Caddy receives
only that runtime path; neither plaintext value enters the Nix store.

After rebuilding, verify that Caddy obtains a certificate and that no A or AAAA
record for the private name exists in public DNS:

```console
curl --fail https://caddy.home.hyrax.fyi/healthz
sudo journalctl --unit caddy --since today
```

Caddy's certificate and account state lives in `/var/lib/caddy`. It is
reconstructable through DNS-01 and does not need to be treated as critical
backup data.
