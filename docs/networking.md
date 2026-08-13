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

## Caddy bootstrap

The initial configuration enables Caddy at:

```text
http://caddy.home.hyrax.fyi/healthz
```

This intentionally remains HTTP until Porkbun credentials have been encrypted
with SOPS. It provides a way to verify DNS, firewall, and Caddy independently
of certificate issuance.

After deployment, verify it from another LAN machine:

```console
curl --fail http://caddy.home.hyrax.fyi/healthz
```

The response must be `ok`. Other paths are aborted rather than serving a
default site.

## Porkbun DNS-01 credentials

Create a Porkbun API key for certificate management and enable API access for
`hyrax.fyi`. Treat both the API key and secret key as secrets. Add them to
`secrets/homeserver.yaml` using the workflow in `docs/secrets.md`:

```yaml
caddy:
  porkbun_api_key: replace-me
  porkbun_api_secret_key: replace-me
```

Then declare the two SOPS secrets and render a root-owned environment file in
the host configuration:

```nix
sops = {
  defaultSopsFile = ../../secrets/homeserver.yaml;
  secrets = {
    "caddy/porkbun_api_key" = { };
    "caddy/porkbun_api_secret_key" = { };
  };
  templates."caddy-porkbun.env" = {
    owner = "caddy";
    group = "caddy";
    mode = "0400";
    content = ''
      PORKBUN_API_KEY=${config.sops.placeholder."caddy/porkbun_api_key"}
      PORKBUN_API_SECRET_KEY=${config.sops.placeholder."caddy/porkbun_api_secret_key"}
    '';
  };
};

homelab.reverseProxy = {
  enableDnsChallenge = true;
  porkbunEnvironmentFile = config.sops.templates."caddy-porkbun.env".path;
};
```

Rebuild first with Let's Encrypt's staging endpoint if repeated certificate
testing is necessary. Once enabled, verify that Caddy obtains a certificate and
that no A or AAAA record for the private name exists in public DNS:

```console
curl --fail https://caddy.home.hyrax.fyi/healthz
sudo journalctl --unit caddy --since today
```

Caddy's certificate and account state lives in `/var/lib/caddy`. It is
reconstructable through DNS-01 and does not need to be treated as critical
backup data.
