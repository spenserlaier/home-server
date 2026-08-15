# Private networking and DNS

The household portal uses `home.hyrax.fyi`, and private services use names
below it. They are not published with public A or AAAA records and the router
must not forward ports 80 or 443 from the internet. Caddy is the only HTTP
entry point for the portal and application services.

The target resolution path is:

```text
LAN client      -> Pi-hole -> homeserver LAN address
NetBird client  -> Pi-hole -> homeserver LAN address through NetBird routing
public resolver -> no private address
```

Pi-hole now declares these private records on the homeserver. Follow the staged
migration and rollback procedure in [pihole.md](./pihole.md). Until a client is
pointed at the new resolver, add individual records to the existing router DNS
if it supports them. Otherwise, add a temporary hosts-file entry on the client:

```text
192.168.4.22 home.hyrax.fyi caddy.home.hyrax.fyi jellyfin.home.hyrax.fyi paperless.home.hyrax.fyi invoices.home.hyrax.fyi ntfy.home.hyrax.fyi pihole.home.hyrax.fyi
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

## Household portal

The static household portal is available at:

```text
https://home.hyrax.fyi
```

It links only to household-facing services. It contains no application
credentials, administrative links, live service data, or third-party assets.
Its availability message describes network scope and is not a live health
indicator; operational monitoring remains responsible for failure detection.

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

Certificate issuance checks propagation through public recursive resolvers,
rather than depending on the server's LAN resolver. It waits up to ten minutes
because Porkbun challenge records currently have a 600-second TTL.

After rebuilding, verify that Caddy obtains a certificate and that no A or AAAA
record for the private name exists in public DNS:

```console
curl --fail https://caddy.home.hyrax.fyi/healthz
sudo journalctl --unit caddy --since today
```

Caddy's certificate and account state lives in `/var/lib/caddy`. It is
reconstructable through DNS-01 and does not need to be treated as critical
backup data.

## Host firewall trust boundary

The router remains the perimeter firewall, with no IPv4 port forwards or IPv6
firewall exceptions for the homeserver. The host independently permits its
network services only when the source address belongs to the declared physical
LAN subnet, currently `192.168.4.0/24`:

```text
TCP 22       SSH administration
TCP/UDP 53   Pi-hole DNS
TCP 80       HTTPS redirects
TCP/UDP 443  Caddy HTTPS and HTTP/3
```

The global NixOS allowed-port lists remain empty. The source-qualified rules
have no IPv6 equivalent, so new IPv6 connections to these services are denied.
Loopback application listeners and established outbound connections are not
affected.

Before activating a subnet change, confirm that the administrative client
routes directly to the server and has an address inside the declared subnet:

```console
# macOS
route -n get 192.168.4.22

# Linux
ip route get 192.168.4.22
```

Use a test activation for firewall changes so a reboot returns to the previous
boot configuration if SSH access is unexpectedly lost:

```console
sudo nixos-rebuild test --flake .#homeserver
```

Keep the existing SSH session open, establish a second fresh SSH connection,
then verify DNS and HTTPS from another LAN client before switching the
configuration persistently.

An eventual NetBird deployment will introduce a separate overlay interface and
address range. Add narrowly scoped rules for the required ports from NetBird's
actual client subnet at that time. Do not add commercial VPN exit ranges:
Mullvad local-network sharing routes LAN traffic directly, so the server sees
the client's `192.168.4.x` address rather than a Mullvad exit address.

If rollback is required while the test configuration is active, reboot from a
local console or use the still-open administrative session:

```console
sudo nixos-rebuild switch --rollback
```
