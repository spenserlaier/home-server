# Pi-hole DNS migration

Pi-hole runs in the official container and publishes DNS only on the
router-reserved homeserver address, `192.168.4.22`. The admin interface remains
loopback-only behind Caddy at:

```text
https://pihole.home.hyrax.fyi/admin/
```

The host itself continues to use the DNS servers supplied by DHCP. It does not
use Pi-hole, so a Pi-hole failure cannot prevent the host from resolving the
external services needed for Caddy DNS-01, ntfy, Healthchecks.io, or Kopia.
`systemd-resolved` keeps its loopback stub while Podman binds port 53 only on
`192.168.4.22`, avoiding a port conflict.

Pi-hole is a DNS service only. DHCP remains on the router, and Pi-hole's DHCP
and NTP servers are explicitly disabled. The firewall admits TCP and UDP port
53, but the published socket exists only on the reserved LAN address. Do not
forward port 53, 80, or 443 from the internet.

## Declarative configuration and state

Nix declares the image version, upstream resolvers, local records, listener
behavior, database retention, disabled ancillary services, and dashboard
route. SOPS supplies the generated admin password through a read-only runtime
file; the value does not enter the Nix store or container environment.

The initial upstreams are Cloudflare's `1.1.1.1` and `1.0.0.1`. Change
`homelab.pihole.upstreams` in the host configuration if a different upstream is
preferred.

Writable Pi-hole state lives beneath `/srv/pihole`. It contains the gravity and
query databases, and is deliberately outside `/srv/backups`: local DNS records
and operational settings are reconstructed from Nix/SOPS, the image recreates
its default blocklist, and browsing history should not be copied off-host. Query
history is retained locally for 30 days. If non-default allowlists, denylists,
adlists, groups, or client rules are added later, either declare a reconciliation
mechanism or add a reviewed Teleporter export to the native backup producers
before treating them as recovery-critical.

The declared local records include all current `home.hyrax.fyi` services plus:

```text
homeserver.home.arpa -> 192.168.4.22
scanner.home.arpa    -> 192.168.4.38
```

## Staged deployment

Keep the existing Raspberry Pi resolver available throughout the test-client
stage. Confirm that the router reservation still assigns `192.168.4.22` to the
homeserver, then rebuild. The container cannot publish DNS if that address is
not present on the host.

After activation, verify the unit, listener, direct DNS path, and dashboard:

```console
sudo systemctl status podman-pihole.service
sudo journalctl --unit podman-pihole.service --since today
sudo ss --tcp --udp --listening --numeric | grep ':53 '
dig @192.168.4.22 pihole.home.hyrax.fyi A
dig @192.168.4.22 homeserver.home.arpa A
dig @192.168.4.22 example.com A
curl --fail https://pihole.home.hyrax.fyi/admin/
sudo systemctl start pihole-dns-check.service
```

The local names must return `192.168.4.22`, and the external query must return
at least one address. A five-minute timer repeats both checks. Failure creates a
durable local alert and sends ntfy through its loopback endpoint; recovery
clears that alert. Healthchecks.io continues to establish whether the hardware
itself is reachable independently of Pi-hole.

Retrieve the dashboard password only when needed, without creating a decrypted
file:

```console
sops decrypt --extract '["pihole"]["admin_password"]' secrets/homeserver.yaml
```

Next, configure one test client to use only `192.168.4.22` for DNS. Do not add a
public secondary resolver: clients may bypass Pi-hole unpredictably rather than
using it only during a failure. Renew the client's network lease or flush its
DNS cache, then verify:

* current private HTTPS services load by name;
* ordinary external names resolve;
* a domain from the active gravity list is blocked;
* the Pi-hole query log identifies the test client;
* ntfy desktop delivery still works through `ntfy.home.hyrax.fyi`.

This is also the point to configure the Android ntfy application once, using
the now-stable private DNS name and the `spenser-phone` account.

Inventory any non-default lists and rules on the old Pi-hole and recreate only
the ones still wanted. Avoid importing a complete old Teleporter archive over
the new instance without review, because it may carry obsolete network and
service settings that conflict with the environment-managed configuration.

After the test client has remained healthy, change the router's DHCP-advertised
DNS server to `192.168.4.22`, renew a small set of representative clients, and
then allow ordinary lease renewal to migrate the rest of the LAN. Leave DHCP on
the router.

## Rollback

Before the router-wide change, rollback is simply removing the manual DNS
setting from the test client. Afterward, restore the router's previous
DHCP-advertised resolver and renew client leases. The existing Raspberry Pi
should remain unchanged and available until the LAN-wide migration has been
stable long enough to make its retirement a separate decision.

Stopping Pi-hole does not affect the homeserver's own external DNS:

```console
sudo systemctl stop podman-pihole.service
```

Do not delete `/srv/pihole` during rollback; retaining it makes a restart or
configuration correction reversible.
